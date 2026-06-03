class MultisigController < ApplicationController
  before_action :authenticate_user

  # POST /create_multisig_wallet
  # params: name, chain_id, owners (array of {address, user_id?}), threshold, safe_address
  def create_wallet
    name = params[:name].to_s.strip
    chain_id = params[:chain_id].to_i
    threshold = params[:threshold].to_i
    safe_address = params[:safe_address].to_s.downcase.strip
    owners = params[:owners]

    raise AppError.new("Name is required") if name.blank?
    raise AppError.new("Invalid chain_id") unless chain_id > 0
    raise AppError.new("Safe address is required") if safe_address.blank?
    raise AppError.new("Owners must be an array") unless owners.is_a?(Array)
    raise AppError.new("At least 2 owners required") if owners.length < 2
    raise AppError.new("Invalid threshold") unless threshold >= 1 && threshold <= owners.length

    owner_addresses = owners.map { |o| o[:address].to_s.downcase }
    raise AppError.new("Current user must be an owner") unless owner_addresses.include?(current_user.evm_chain_active_key&.downcase)

    # Ensure no duplicate address
    raise AppError.new("Duplicate owner addresses") if owner_addresses.uniq.length != owner_addresses.length

    # Check if wallet already exists
    raise AppError.new("Wallet already exists") if Wallet.find_by(evm_chain_address: safe_address)

    wallet = nil
    ActiveRecord::Base.transaction do
      wallet = Wallet.create!(
        user_id: current_user.id,
        name: name,
        wallet_type: "multisig",
        chain: chain_id.to_s,
        chain_id: chain_id,
        evm_chain_address: safe_address,
        threshold: threshold,
        format: "safe_4337"
      )

      owner_addresses.sort.each_with_index do |addr, idx|
        owner_user = User.find_by("LOWER(evm_chain_active_key) = ?", addr)
        matched_owner = owners.find { |o| o[:address].to_s.downcase == addr }
        WalletOwner.create!(
          wallet_id: wallet.id,
          user_id: matched_owner&.dig(:user_id) || owner_user&.id,
          owner_address: addr,
          position: idx
        )
      end
    end

    render json: { result: "ok", wallet: serialize_wallet(wallet) }
  end

  # GET /get_multisig_wallets
  def get_wallets
    owned_addresses = WalletOwner.where("LOWER(owner_address) = ?", current_user.evm_chain_active_key&.downcase)
                                  .pluck(:wallet_id)
    wallets = Wallet.where(id: owned_addresses, wallet_type: "multisig").order(created_at: :desc)

    render json: {
      result: "ok",
      wallets: wallets.map { |w| serialize_wallet(w) }
    }
  end

  # GET /get_multisig_wallet_owners?wallet_id=xxx
  def get_wallet_owners
    wallet = find_multisig_wallet(params[:wallet_id])
    owners = wallet.wallet_owners.order(:position).map do |wo|
      user = wo.user
      {
        id: wo.id,
        owner_address: wo.owner_address,
        position: wo.position,
        user_id: wo.user_id,
        handle: user&.handle,
        phone: user&.phone,
        image_url: user&.image_url
      }
    end

    render json: { result: "ok", owners: owners, threshold: wallet.threshold }
  end

  # POST /sync_multisig_wallet
  # Sync owners/threshold from chain data provided by frontend
  # params: wallet_id, owners (array of addresses), threshold
  def sync_wallet
    wallet = find_multisig_wallet(params[:wallet_id])
    ensure_is_owner!(wallet)

    chain_owners = Array(params[:owners]).map(&:downcase)
    chain_threshold = params[:threshold].to_i

    raise AppError.new("Invalid data from chain") if chain_owners.empty? || chain_threshold < 1

    ActiveRecord::Base.transaction do
      wallet.wallet_owners.destroy_all
      chain_owners.sort.each_with_index do |addr, idx|
        owner_user = User.find_by("LOWER(evm_chain_active_key) = ?", addr)
        WalletOwner.create!(
          wallet_id: wallet.id,
          user_id: owner_user&.id,
          owner_address: addr,
          position: idx
        )
      end
      wallet.update!(threshold: chain_threshold)
    end

    # 链上同步后，重新评估活跃交易状态
    reassess_active_tx_statuses!(wallet)

    render json: { result: "ok" }
  end

  # POST /propose_multisig_tx
  # params: wallet_id, tx_type, call_detail, evm_call_data, replaces_tx_id?, user_op_snapshot? (cancel)
  def propose_tx
    wallet = find_multisig_wallet(params[:wallet_id])
    ensure_is_owner!(wallet)

    tx_type = params[:tx_type].to_s
    raise AppError.new("Invalid tx_type") unless MultisigTransaction::TX_TYPES.include?(tx_type)

    call_detail = params[:call_detail].to_unsafe_h rescue {}
    evm_call_data = params[:evm_call_data].to_s
    replaces_tx_id = params[:replaces_tx_id].to_s.presence
    expires_at = 5.days.from_now

    replaces_tx = nil
    if replaces_tx_id.present?
      replaces_tx = wallet.multisig_transactions.find_by(id: replaces_tx_id)
      raise AppError.new("Referenced transaction not found") unless replaces_tx
      raise AppError.new("Can only replace active transactions") if replaces_tx.terminal?
    end

    tx = nil
    ActiveRecord::Base.transaction do
      if tx_type == "cancel"
        raise AppError.new("replaces_tx_id is required for cancel transactions") unless replaces_tx

        if replaces_tx.tx_type == "cancel"
          raise AppError.new(
            "Cannot propose rejection for a rejection transaction",
            code: "reject_target_is_cancel"
          )
        end

        unless %w[signing ready].include?(replaces_tx.status)
          raise AppError.new(
            "This transaction has not entered signing yet and cannot be rejected on-chain. " \
            "The proposer may withdraw it; others may wait until someone signs or it expires.",
            code: "reject_not_signing"
          )
        end

        if replaces_tx.multisig_signatures.count == 0
          raise AppError.new(
            "At least one signature is required before proposing a rejection",
            code: "reject_not_signing"
          )
        end

        raise AppError.new("Target transaction has no locked nonce yet", code: "reject_not_signing") if replaces_tx.nonce.blank?

        existing_reject = wallet.multisig_transactions.active.find_by(tx_type: "cancel", replaces_tx_id: replaces_tx.id)
        if existing_reject
          raise AppError.new(
            "A rejection transaction is already pending for this transaction",
            code: "reject_already_pending",
            data: { reject_tx_id: existing_reject.id }
          )
        end

        user_op_snapshot = params[:user_op_snapshot]
        raise AppError.new("user_op_snapshot is required for cancel transactions") if user_op_snapshot.blank?

        snapshot_data = user_op_snapshot.is_a?(Hash) ? user_op_snapshot.to_unsafe_h : user_op_snapshot
        snapshot_nonce = snapshot_data[:nonce].to_s
        raise AppError.new("Cancel snapshot nonce must match the target transaction nonce") unless snapshot_nonce == replaces_tx.nonce.to_s

        call_detail = call_detail.merge("replaces_tx_id" => replaces_tx.id)

        tx = MultisigTransaction.create!(
          wallet_id: wallet.id,
          proposer_id: current_user.id,
          chain_id: wallet.chain_id || wallet.chain.to_i,
          queue_position: nil,
          nonce: replaces_tx.nonce,
          tx_type: tx_type,
          call_detail: call_detail,
          evm_call_data: evm_call_data.presence || "0x",
          threshold_at_creation: wallet.threshold,
          replaces_tx_id: replaces_tx.id,
          status: "signing",
          user_op_snapshot: snapshot_data,
          owner_snapshot: MultisigTransaction.build_owner_snapshot(wallet),
          expires_at: expires_at
        )
      else
        raise AppError.new("replaces_tx_id is only valid for cancel transactions") if replaces_tx_id.present?

        next_position = next_queue_position(wallet.id)
        tx = MultisigTransaction.create!(
          wallet_id: wallet.id,
          proposer_id: current_user.id,
          chain_id: wallet.chain_id || wallet.chain.to_i,
          queue_position: next_position,
          tx_type: tx_type,
          call_detail: call_detail,
          evm_call_data: evm_call_data,
          threshold_at_creation: wallet.threshold,
          replaces_tx_id: nil,
          status: "queued",
          owner_snapshot: MultisigTransaction.build_owner_snapshot(wallet),
          expires_at: expires_at
        )
      end
    end

    render json: { result: "ok", tx: serialize_tx(tx) }
  end

  # GET /get_multisig_txs?wallet_id=xxx&scope=queue|history
  def get_txs
    wallet = find_multisig_wallet(params[:wallet_id])
    scope = params[:scope] == "history" ? "history" : "queue"

    txs = if scope == "history"
      wallet.multisig_transactions.history.includes(:multisig_signatures).order(created_at: :desc).limit(50)
    else
      queued = wallet.multisig_transactions.active.includes(:multisig_signatures).in_queue_order.to_a
      competing = wallet.multisig_transactions.active.includes(:multisig_signatures).competing.order(created_at: :asc).to_a
      all_active = queued + competing
      # 修正活跃交易状态
      all_active.each { |tx| reassess_single_tx_status!(tx, wallet) }
      all_active
    end

    render json: {
      result: "ok",
      txs: txs.map { |tx| serialize_tx(tx) }
    }
  end

  # GET /get_multisig_tx?id=xxx
  def get_tx
    tx = MultisigTransaction.find_by(id: params[:id])
    raise AppError.new("Transaction not found") unless tx
    wallet = find_multisig_wallet(tx.wallet_id)

    # 加载时修正状态：确保 signing/ready 与当前门限一致
    reassess_single_tx_status!(tx, wallet)

    render json: { result: "ok", tx: serialize_tx(tx.reload, include_signatures: true) }
  end

  # POST /submit_multisig_signature
  # params: multisig_tx_id, signer_address, signature
  # First signer also provides: nonce, user_op_snapshot
  def submit_signature
    tx = MultisigTransaction.find_by(id: params[:multisig_tx_id])
    raise AppError.new("Transaction not found") unless tx
    wallet = find_multisig_wallet(tx.wallet_id)
    ensure_is_owner!(wallet)

    raise AppError.new("Transaction is not in a signable state") unless %w[queued signing].include?(tx.status)
    raise AppError.new("Transaction has expired") if tx.expires_at && tx.expires_at < Time.current

    signer_address = params[:signer_address].to_s.downcase
    signature = params[:signature].to_s

    # 验证 signer_address 属于当前登录用户
    user_address = current_user.evm_chain_active_key&.downcase
    raise AppError.new("Signer address must match your wallet address") unless user_address && signer_address == user_address

    raise AppError.new("Signer is not an owner of this wallet") unless wallet_owner_addresses(wallet).include?(signer_address)
    raise AppError.new("Invalid signature") if signature.blank?

    MultisigSignature.find_by(multisig_transaction_id: tx.id, signer_address: signer_address)&.tap do
      raise AppError.new("Already signed")
    end

    ActiveRecord::Base.transaction do
      if tx.status == "queued"
        # First signer on a queued tx — must be front of queue and provide snapshot
        active_queue = wallet.multisig_transactions.active.in_queue_order
        raise AppError.new("Only the front-of-queue transaction can be signed") unless tx.front_of_queue?(active_queue)

        nonce = params[:nonce].to_s
        user_op_snapshot = params[:user_op_snapshot]

        raise AppError.new("nonce is required for first signature") if nonce.blank?
        raise AppError.new("user_op_snapshot is required for first signature") if user_op_snapshot.blank?

        snapshot_data = user_op_snapshot.is_a?(Hash) ? user_op_snapshot.to_unsafe_h : user_op_snapshot

        tx.update!(
          status: "signing",
          nonce: nonce,
          user_op_snapshot: snapshot_data
        )
      elsif tx.competing_replacement? && tx.user_op_snapshot.blank?
        raise AppError.new("Rejection transaction is missing user_op_snapshot")
      end

      MultisigSignature.create!(
        multisig_transaction_id: tx.id,
        signer_address: signer_address,
        signature: signature
      )

      # 以"当前"门限与"当前" owner 集合判定是否达标（与链上 Safe 校验一致）
      current_owner_addresses = wallet.wallet_owners.pluck(:owner_address).map { |a| a.to_s.downcase }
      eligible_count = tx.multisig_signatures.where("LOWER(signer_address) IN (?)", current_owner_addresses).count
      if eligible_count >= wallet.threshold
        tx.update!(status: "ready")
      end
    end

    render json: { result: "ok", tx: serialize_tx(tx.reload, include_signatures: true) }
  rescue ActiveRecord::RecordNotUnique
    raise AppError.new("Already signed")
  end

  # POST /execute_multisig_tx
  # params: multisig_tx_id
  # Marks as executing and returns snapshot + signatures for frontend to submit
  def execute_tx
    tx = MultisigTransaction.find_by(id: params[:multisig_tx_id])
    raise AppError.new("Transaction not found") unless tx
    wallet = find_multisig_wallet(tx.wallet_id)
    ensure_is_owner!(wallet)

    raise AppError.new("Transaction is not ready to execute") unless tx.status == "ready"

    # 原子更新：防止并发重复执行
    updated = MultisigTransaction.where(id: tx.id, status: "ready").update_all(status: "executing")
    raise AppError.new("Transaction is no longer ready to execute") unless updated > 0

    render json: {
      result: "ok",
      tx: serialize_tx(tx, include_signatures: true)
    }
  end

  # POST /confirm_multisig_tx
  # params: multisig_tx_id, tx_hash
  # Called by frontend after successful on-chain execution
  def confirm_tx
    tx = MultisigTransaction.find_by(id: params[:multisig_tx_id])
    raise AppError.new("Transaction not found") unless tx
    wallet = find_multisig_wallet(tx.wallet_id)
    ensure_is_owner!(wallet)

    raise AppError.new("Transaction is not in executing state") unless tx.status == "executing"

    tx_hash = params[:tx_hash].to_s
    raise AppError.new("tx_hash is required") if tx_hash.blank?

    nonce = tx.nonce

    ActiveRecord::Base.transaction do
      tx.update!(status: "executed", tx_hash: tx_hash)

      # Advance queue based on executed tx or the tx it replaced
      advance_from = tx.queue_position
      if advance_from.nil? && tx.replaces_tx_id.present?
        replaced = MultisigTransaction.find_by(id: tx.replaces_tx_id)
        advance_from = replaced&.queue_position
      end
      if advance_from.present?
        wallet.multisig_transactions
              .active
              .where.not(queue_position: nil)
              .where("queue_position > ?", advance_from)
              .update_all("queue_position = queue_position - 1")
      end

      # Mark all other active txs with same nonce as superseded
      superseded_txs = []
      if nonce.present?
        superseded_txs = wallet.multisig_transactions
                               .active
                               .where(nonce: nonce)
                               .where.not(id: tx.id)
                               .to_a
        superseded_txs.each { |stx| stx.update!(status: "superseded") }
      end

      apply_wallet_config_from_executed_tx!(wallet, tx)

      # 冻结终态交易的 owner 快照
      tx.freeze_owner_snapshot!
      superseded_txs.each(&:freeze_owner_snapshot!)
    end

    render json: { result: "ok" }
  end

  # POST /fail_multisig_tx
  # params: multisig_tx_id
  def fail_tx
    tx = MultisigTransaction.find_by(id: params[:multisig_tx_id])
    raise AppError.new("Transaction not found") unless tx
    wallet = find_multisig_wallet(tx.wallet_id)
    ensure_is_owner!(wallet)

    raise AppError.new("Transaction is not in executing state") unless tx.status == "executing"

    tx.update!(status: "failed")
    tx.freeze_owner_snapshot!
    render json: { result: "ok" }
  end

  # POST /withdraw_multisig_tx
  # params: multisig_tx_id
  # Only proposer can withdraw, only if still queued (no signatures)
  def withdraw_tx
    tx = MultisigTransaction.find_by(id: params[:multisig_tx_id])
    raise AppError.new("Transaction not found") unless tx
    find_multisig_wallet(tx.wallet_id)

    raise AppError.new("Only the proposer can withdraw") unless tx.proposer_id == current_user.id
    raise AppError.new("Can only withdraw queued transactions with no signatures") unless tx.status == "queued"
    raise AppError.new("Cannot withdraw a transaction that has been signed") if tx.signature_count > 0

    ActiveRecord::Base.transaction do
      withdrawn_pos = tx.queue_position
      tx.update!(status: "withdrawn", queue_position: nil)

      # Shift remaining queue positions forward
      MultisigTransaction.active
                         .where(wallet_id: tx.wallet_id)
                         .where("queue_position > ?", withdrawn_pos)
                         .update_all("queue_position = queue_position - 1")
    end

    tx.freeze_owner_snapshot!
    render json: { result: "ok" }
  end

  private

  def find_multisig_wallet(wallet_id)
    wallet = Wallet.find_by(id: wallet_id, wallet_type: "multisig")
    raise AppError.new("Wallet not found") unless wallet
    wallet
  end

  def ensure_is_owner!(wallet)
    addresses = wallet_owner_addresses(wallet)
    raise AppError.new("You are not an owner of this wallet") unless addresses.include?(current_user.evm_chain_active_key&.downcase)
  end

  def wallet_owner_addresses(wallet)
    wallet.wallet_owners.pluck(:owner_address)
  end

  def apply_wallet_config_from_executed_tx!(wallet, tx)
    return unless %w[add_owner remove_owner change_threshold replace_owner].include?(tx.tx_type)

    detail = tx.call_detail.is_a?(Hash) ? tx.call_detail.with_indifferent_access : {}

    case tx.tx_type
    when "remove_owner"
      owner_addr = detail[:owner].to_s.downcase.strip
      new_threshold = detail[:new_threshold].to_i
      raise AppError.new("Invalid remove_owner call_detail") if owner_addr.blank?

      wallet.wallet_owners.where("LOWER(owner_address) = ?", owner_addr).destroy_all
      reorder_wallet_owner_positions!(wallet)
      wallet.update!(threshold: new_threshold) if new_threshold >= 1

    when "add_owner"
      new_owner = detail[:new_owner].to_s.downcase.strip
      new_threshold = detail[:new_threshold].to_i
      raise AppError.new("Invalid add_owner call_detail") if new_owner.blank?

      unless wallet.wallet_owners.where("LOWER(owner_address) = ?", new_owner).exists?
        owner_user = User.find_by("LOWER(evm_chain_active_key) = ?", new_owner)
        max_pos = wallet.wallet_owners.maximum(:position) || -1
        WalletOwner.create!(
          wallet_id: wallet.id,
          user_id: owner_user&.id,
          owner_address: new_owner,
          position: max_pos + 1
        )
      end
      wallet.update!(threshold: new_threshold) if new_threshold >= 1

    when "change_threshold"
      new_threshold = detail[:new_threshold].to_i
      raise AppError.new("Invalid change_threshold call_detail") unless new_threshold >= 1

      wallet.update!(threshold: new_threshold)

    when "replace_owner"
      old_owner = detail[:old_owner].to_s.downcase.strip
      new_owner = detail[:new_owner].to_s.downcase.strip
      raise AppError.new("Invalid replace_owner call_detail") if old_owner.blank? || new_owner.blank?

      wallet.wallet_owners.where("LOWER(owner_address) = ?", old_owner).destroy_all

      unless wallet.wallet_owners.where("LOWER(owner_address) = ?", new_owner).exists?
        owner_user = User.find_by("LOWER(evm_chain_active_key) = ?", new_owner)
        max_pos = wallet.wallet_owners.maximum(:position) || -1
        WalletOwner.create!(
          wallet_id: wallet.id,
          user_id: owner_user&.id,
          owner_address: new_owner,
          position: max_pos + 1
        )
      end
      reorder_wallet_owner_positions!(wallet)
    end

    # 人员/门限变更后，重新评估活跃交易状态（与链上 Safe 校验一致）
    reassess_active_tx_statuses!(wallet)
  end

  # 当门限或 owner 集合变更后，重新评估该钱包所有活跃交易的 status
  # 签名数已达当前门限的 signing 交易应升级为 ready
  # 原为 ready 但签名数不再满足当前门限的应降为 signing
  # 同时更新活跃交易的 owner_snapshot 以反映最新 owner 集合
  def reassess_active_tx_statuses!(wallet)
    current_owner_addresses = wallet.wallet_owners.pluck(:owner_address).map { |a| a.to_s.downcase }
    current_threshold = wallet.threshold

    wallet.multisig_transactions.where(status: %w[queued signing ready]).find_each do |tx|
      # 更新快照为当前 owner 集合（保留已有签名状态）
      update_active_tx_snapshot!(tx, wallet)
      reassess_single_tx_status!(tx, wallet, current_owner_addresses, current_threshold)
    end
  end

  # 评估单个交易状态是否与当前门限/owner一致
  def reassess_single_tx_status!(tx, wallet, current_owner_addresses = nil, current_threshold = nil)
    return unless %w[signing ready].include?(tx.status)

    current_owner_addresses ||= wallet.wallet_owners.pluck(:owner_address).map { |a| a.to_s.downcase }
    current_threshold ||= wallet.threshold

    eligible_count = tx.multisig_signatures
                       .where("LOWER(signer_address) IN (?)", current_owner_addresses)
                       .count

    if tx.status == "signing" && eligible_count >= current_threshold
      tx.update!(status: "ready")
    elsif tx.status == "ready" && eligible_count < current_threshold
      tx.update!(status: "signing")
    end
  end

  # 更新活跃交易的 owner_snapshot 为当前 owner 集合，保留已有签名状态
  def update_active_tx_snapshot!(tx, wallet)
    signed_addresses = tx.multisig_signatures.pluck(:signer_address).map(&:downcase)
    signed_at_map = tx.multisig_signatures.map { |s| [s.signer_address.downcase, s.created_at] }.to_h

    new_snapshot = wallet.wallet_owners.order(:position).map do |wo|
      user = wo.user
      addr = wo.owner_address.downcase
      entry = {
        "address" => wo.owner_address,
        "name" => user&.handle || user&.phone,
        "signed" => signed_addresses.include?(addr)
      }
      if signed_at_map[addr]
        entry["signed_at"] = signed_at_map[addr].iso8601
      end
      entry
    end

    tx.update_column(:owner_snapshot, new_snapshot)
  end

  def reorder_wallet_owner_positions!(wallet)
    wallet.wallet_owners.order(:position).each_with_index do |wo, idx|
      wo.update_column(:position, idx)
    end
  end

  def next_queue_position(wallet_id)
    max_pos = MultisigTransaction.where(wallet_id: wallet_id).active.maximum(:queue_position)
    max_pos ? max_pos + 1 : 1
  end

  def serialize_wallet(wallet)
    {
      id: wallet.id,
      name: wallet.name,
      wallet_type: wallet.wallet_type,
      chain_id: wallet.chain_id || wallet.chain.to_i,
      safe_address: wallet.evm_chain_address,
      threshold: wallet.threshold,
      created_at: wallet.created_at
    }
  end

  def serialize_tx(tx, include_signatures: false)
    wallet = tx.wallet
    current_owner_addresses = wallet.wallet_owners.pluck(:owner_address).map { |a| a.to_s.downcase }
    current_threshold = wallet.threshold
    signer_addresses = tx.multisig_signatures.map(&:signer_address)

    is_terminal = MultisigTransaction::TERMINAL_STATUSES.include?(tx.status)

    if is_terminal
      # 终态交易：使用快照数据（交易完成/失效时的状态）
      display_threshold = tx.threshold_at_creation
      display_signature_count = tx.signature_count
      display_eligible_count = tx.signature_count
    else
      # 活跃交易：使用当前实时数据（与链上 Safe 校验一致）
      display_threshold = current_threshold
      display_eligible_count = signer_addresses.count { |a| current_owner_addresses.include?(a.to_s.downcase) }
      display_signature_count = tx.signature_count
    end

    data = {
      id: tx.id,
      wallet_id: tx.wallet_id,
      proposer_id: tx.proposer_id,
      chain_id: tx.chain_id,
      queue_position: tx.queue_position,
      nonce: tx.nonce,
      tx_type: tx.tx_type,
      call_detail: tx.call_detail,
      evm_call_data: tx.evm_call_data,
      threshold_at_creation: tx.threshold_at_creation,
      current_threshold: current_threshold,
      current_owners: current_owner_addresses,
      replaces_tx_id: tx.replaces_tx_id,
      status: tx.status,
      tx_hash: tx.tx_hash,
      expires_at: tx.expires_at,
      signature_count: display_signature_count,
      eligible_signature_count: display_eligible_count,
      signer_addresses: signer_addresses,
      owner_snapshot: tx.owner_snapshot,
      created_at: tx.created_at,
      updated_at: tx.updated_at
    }

    if include_signatures
      data[:signatures] = tx.signatures_data
      data[:user_op_snapshot] = tx.user_op_snapshot
    end

    if tx.tx_type != "cancel"
      pending = wallet.multisig_transactions.active.find_by(
        tx_type: "cancel",
        replaces_tx_id: tx.id
      )
      data[:pending_reject_tx_id] = pending&.id
    end

    data
  end
end
