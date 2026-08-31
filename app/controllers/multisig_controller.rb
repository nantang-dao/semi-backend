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

    # Compute pending signature counts for each wallet
    user_addr = current_user.evm_chain_active_key&.downcase
    pending_counts = {}
    if user_addr.present?
      wallets.each do |w|
        # Count active transactions where the user hasn't signed yet
        active_txs = w.multisig_transactions.active.includes(:multisig_signatures).to_a
        count = 0
        active_txs.each do |tx|
          has_signed = tx.multisig_signatures.where("LOWER(signer_address) = ?", user_addr).exists?
          count += 1 unless has_signed
        end
        pending_counts[w.id] = count
      end
    end

    render json: {
      result: "ok",
      wallets: wallets.map { |w| serialize_wallet(w) },
      pending_signature_counts: pending_counts
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
  # Sync owners/threshold — 后端从链上验证，前端仅触发
  # params: wallet_id, owners (array of addresses), threshold
  def sync_wallet
    wallet = find_multisig_wallet(params[:wallet_id])
    ensure_is_owner!(wallet)

    chain_owners = Array(params[:owners]).map(&:downcase)
    chain_threshold = params[:threshold].to_i

    raise AppError.new("Invalid data from chain") if chain_owners.empty? || chain_threshold < 1

    # 后端从链上验证 owners 和 threshold 的真实性
    safe_address = wallet.evm_chain_address
    chain_id = wallet.chain_id || wallet.chain.to_i
    if safe_address.present?
      begin
        onchain_owners = ChainRpc.get_owners(safe_address, chain_id)
        onchain_threshold = ChainRpc.get_threshold(safe_address, chain_id)

        if onchain_owners.present?
          # 验证前端提交的数据与链上一致
          onchain_owners_normalized = onchain_owners.map(&:downcase).sort
          chain_owners_normalized = chain_owners.sort
          unless onchain_owners_normalized == chain_owners_normalized && onchain_threshold == chain_threshold
            raise AppError.new("Submitted data does not match on-chain state")
          end
        end
        # 如果链上读取失败（RPC 不可用），降级为信任前端数据（记录日志）
      rescue => e
        Rails.logger.warn("ChainRpc verification skipped for wallet #{wallet.id}: #{e.message}")
      end
    end

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
    memo = params[:memo].to_s.strip.presence
    sender_note = params[:sender_note].to_s.strip.presence
    expires_at = 5.days.from_now

    # 验证配置类交易的 callData 函数选择器与 tx_type 匹配
    validate_config_calldata!(tx_type, evm_call_data, call_detail)

    # 为配置类交易补充地址对应的名字到 call_detail
    call_detail = enrich_call_detail_names(call_detail, wallet)

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
          expires_at: expires_at,
          memo: memo,
          sender_note: sender_note
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
          expires_at: expires_at,
          memo: memo,
          sender_note: sender_note
        )
      end
    end

    render json: { result: "ok", tx: serialize_tx(tx) }
  end

  # GET /get_multisig_txs?wallet_id=xxx&scope=queue|history
  def get_txs
    wallet = find_multisig_wallet(params[:wallet_id])
    ensure_is_owner!(wallet)

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
    ensure_is_owner!(wallet)

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
    user_active_key = current_user.evm_chain_active_key.to_s.downcase
    raise AppError.new("Signer address must match your wallet address") unless signer_address == user_active_key

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
  # params: multisig_tx_id, tx_hash, gas_used, user_op_hash（可选，用于精确定位 UserOp）
  # Called by frontend after successful on-chain execution
  def confirm_tx
    tx = MultisigTransaction.find_by(id: params[:multisig_tx_id])
    raise AppError.new("Transaction not found") unless tx
    wallet = find_multisig_wallet(tx.wallet_id)
    ensure_is_owner!(wallet)

    raise AppError.new("Transaction is not in executing state") unless tx.status == "executing"

    tx_hash = params[:tx_hash].to_s
    raise AppError.new("tx_hash is required") if tx_hash.blank?

    # 失败闭合（fail-closed）链上校验：必须能从链上读到该 tx_hash 的成功回执，且该回执
    # 确实属于本 Safe 的 ERC-4337 UserOp，才允许标记 executed 并应用 owner/threshold 配置变更。
    # 防止伪造/复用无关 tx_hash 把交易标记为已执行。校验在状态推进之前进行，失败时交易
    # 仍停留在 executing（可由 reset_executing_tx 或前端重试恢复），不会卡在 confirming。
    chain_id = wallet.chain_id || wallet.chain.to_i
    verify_userop_receipt!(tx_hash, chain_id, wallet.evm_chain_address, params[:user_op_hash])

    # 校验通过后再原子推进状态：防止并发 confirm 导致 apply_wallet_config 执行两次
    updated = MultisigTransaction.where(id: tx.id, status: "executing").update_all(status: "confirming")
    raise AppError.new("Transaction is no longer in executing state") unless updated > 0
    tx.reload

    nonce = tx.nonce

    # Gas is sponsored by the paymaster on-chain (free for all signers), but the
    # actual cost (wei, from the UserOp receipt's actualGasCost) is accredited to
    # the executor — the "last user" who triggered execution.
    gas_used = params[:gas_used].to_s.presence
    executor = current_user

    ActiveRecord::Base.transaction do
      tx.update!(status: "executed", tx_hash: tx_hash, executor_id: executor.id, gas_used: (gas_used || "0"))

      if gas_used.present? && gas_used.to_d > 0
        executor.increment!(:total_used_gas_credits, gas_used.to_d)
      end

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

      # 冻结终态交易的 owner 快照（必须在 apply_wallet_config 之前，否则快照会反映修改后的 owner 列表）
      tx.freeze_owner_snapshot!
      superseded_txs.each(&:freeze_owner_snapshot!)

      apply_wallet_config_from_executed_tx!(wallet, tx)
    end

    render json: { result: "ok" }
  end

  # POST /reset_executing_multisig_tx
  # 将卡在 executing 状态的交易回滚为 ready，允许重新执行
  # 仅限 owner 调用，且交易必须处于 executing 状态超过 5 分钟
  def reset_executing_tx
    tx = MultisigTransaction.find_by(id: params[:multisig_tx_id])
    raise AppError.new("Transaction not found") unless tx
    wallet = find_multisig_wallet(tx.wallet_id)
    ensure_is_owner!(wallet)

    raise AppError.new("Transaction is being confirmed, cannot reset") if tx.status == "confirming"
    raise AppError.new("Transaction is not in executing state") unless tx.status == "executing"
    raise AppError.new("Transaction is still being executed, please wait a few minutes") unless tx.updated_at < 5.minutes.ago

    tx.update!(status: "ready")
    render json: { result: "ok" }
  end

  # POST /fail_multisig_tx
  # params: multisig_tx_id
  def fail_tx
    tx = MultisigTransaction.find_by(id: params[:multisig_tx_id])
    raise AppError.new("Transaction not found") unless tx
    wallet = find_multisig_wallet(tx.wallet_id)
    ensure_is_owner!(wallet)

    raise AppError.new("Transaction is being confirmed, cannot mark as failed") if tx.status == "confirming"
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
    wallet = find_multisig_wallet(tx.wallet_id)
    ensure_is_owner!(wallet)

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

  # GET /lookup_multisig_tx_memos?tx_hashes=hash1,hash2,...
  # 根据链上 tx_hash 批量查找多签交易的备注（memo + sender_note）
  # 同时查 multisig_transactions 和 transactions 表，大小写不敏感
  def lookup_tx_memos
    hashes_param = params[:tx_hashes].to_s
    raise AppError.new("tx_hashes is required") if hashes_param.blank?

    tx_hashes = hashes_param.split(",").map(&:strip).reject(&:blank?)
    raise AppError.new("No valid tx_hashes") if tx_hashes.empty?

    memos = {}

    downcased = tx_hashes.map(&:downcase)
    MultisigTransaction.where("LOWER(tx_hash) IN (?)", downcased).each do |tx|
      next unless tx.tx_hash.present?
      memos[tx.tx_hash.downcase] = { memo: tx.memo, sender_note: tx.sender_note }
    end

    Transaction.where("LOWER(tx_hash) IN (?)", downcased).each do |tx|
      next unless tx.tx_hash.present?
      key = tx.tx_hash.downcase
      unless memos.key?(key)
        memos[key] = { memo: tx.memo, sender_note: tx.sender_note }
      end
    end

    render json: { result: "ok", memos: memos }
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

  def validate_and_update_threshold!(wallet, new_threshold)
    owner_count = wallet.wallet_owners.count
    if new_threshold < 1 || new_threshold > owner_count
      Rails.logger.error("Invalid threshold #{new_threshold} for #{owner_count} owners on wallet #{wallet.id}, skipping update")
      return
    end
    wallet.update!(threshold: new_threshold)
  end

  # 验证配置类交易的 callData 函数选择器与 tx_type 匹配
  # Safe v1.4.1 函数选择器
  CONFIG_TX_SELECTORS = {
    "add_owner" => "0x0d582f13",      # addOwnerWithThreshold(address,uint256)
    "remove_owner" => "0xf8dc5dd9",   # removeOwner(address,address,uint256)
    "replace_owner" => "0xe318b52b",  # swapOwner(address,address,address)
    "change_threshold" => "0x694e80c3" # changeThreshold(uint256)
  }.freeze

  # 为 call_detail 中的地址补充对应的名字
  # 从全局用户表搜索，确保 add_owner/replace_owner 的新 owner 名字也能显示
  def enrich_call_detail_names(call_detail, wallet)
    detail = call_detail.is_a?(Hash) ? call_detail.with_indifferent_access : {}
    address_fields = [:new_owner, :old_owner, :owner]
    owner_map = wallet.wallet_owners.index_by { |wo| wo.owner_address.downcase }

    address_fields.each do |field|
      addr = detail[field].to_s.downcase.strip
      next if addr.blank?
      next if detail["#{field}_name"].present? # 已有名字则跳过

      # 1. 从当前钱包 owner 列表找
      wo = owner_map[addr]
      if wo&.user
        detail["#{field}_name"] = wo.user.handle || wo.user.phone
        next
      end

      # 2. 从全局用户表找
      user = User.find_by("LOWER(evm_chain_active_key) = ?", addr)
      if user
        detail["#{field}_name"] = user.handle || user.phone
        next
      end
    end

    detail.to_h
  end

  def validate_config_calldata!(tx_type, evm_call_data, call_detail)
    return unless CONFIG_TX_SELECTORS.key?(tx_type)

    expected_selector = CONFIG_TX_SELECTORS[tx_type]
    actual_selector = evm_call_data&.[](0, 10) || ""

    unless actual_selector.downcase == expected_selector.downcase
      raise AppError.new("callData function selector does not match tx_type #{tx_type}: expected #{expected_selector}, got #{actual_selector}")
    end

    # 验证 call_detail 中关键字段不为空
    detail = call_detail.is_a?(Hash) ? call_detail.with_indifferent_access : {}
    case tx_type
    when "add_owner"
      raise AppError.new("call_detail.new_owner is required") if detail[:new_owner].blank?
      raise AppError.new("call_detail.new_threshold is required") if detail[:new_threshold].blank?
    when "remove_owner"
      raise AppError.new("call_detail.owner is required") if detail[:owner].blank?
      raise AppError.new("call_detail.new_threshold is required") if detail[:new_threshold].blank?
    when "replace_owner"
      raise AppError.new("call_detail.old_owner is required") if detail[:old_owner].blank?
      raise AppError.new("call_detail.new_owner is required") if detail[:new_owner].blank?
    when "change_threshold"
      raise AppError.new("call_detail.new_threshold is required") if detail[:new_threshold].blank?
    end
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
      validate_and_update_threshold!(wallet, new_threshold)

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
      validate_and_update_threshold!(wallet, new_threshold)

    when "change_threshold"
      new_threshold = detail[:new_threshold].to_i
      raise AppError.new("Invalid change_threshold call_detail") unless new_threshold >= 1

      validate_and_update_threshold!(wallet, new_threshold)

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
  def reassess_active_tx_statuses!(wallet)
    current_owner_addresses = wallet.wallet_owners.pluck(:owner_address).map { |a| a.to_s.downcase }
    current_threshold = wallet.threshold

    wallet.multisig_transactions.where(status: %w[signing ready]).find_each do |tx|
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

  def reorder_wallet_owner_positions!(wallet)
    wallet.wallet_owners.order(:position).each_with_index do |wo, idx|
      wo.update_column(:position, idx)
    end
  end

  def next_queue_position(wallet_id)
    # 使用 advisory lock 防止并发提案产生相同的 queue_position
    lock_key = Digest::MD5.hexdigest("multisig_queue_#{wallet_id}")[0, 15].to_i(16)
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_lock(#{lock_key})")

    max_pos = MultisigTransaction.where(wallet_id: wallet_id).active.maximum(:queue_position)
    max_pos ? max_pos + 1 : 1
  ensure
    ActiveRecord::Base.connection.execute("SELECT pg_advisory_unlock(#{lock_key})")
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

  # ERC-4337 v0.7 EntryPoint（所有支持链上为同一地址）
  ENTRY_POINT_V07 = "0x0000000071727de22e5e9d8baf0edac6f37da032"

  # 失败闭合校验：链上必须存在该 tx_hash 的成功回执，且回执确实对应本 Safe 的 UserOp。
  # 任一条件不满足即抛错（不降级信任前端），从而阻止伪造/复用无关 tx_hash 的确认。
  def verify_userop_receipt!(tx_hash, chain_id, safe_address, user_op_hash = nil)
    safe = safe_address.to_s.downcase

    # 容忍 RPC 节点同步延迟：短暂重试后仍读不到则失败闭合（让前端稍后重试）。
    receipt = nil
    3.times do |i|
      receipt = ChainRpc.get_transaction_receipt(tx_hash, chain_id)
      break if receipt
      sleep(1.5) if i < 2
    end

    raise AppError.new("链上回执暂不可用，请稍后重试确认（tx 仍可恢复）") if receipt.nil?

    # 注意：这一条只说明**那笔打包交易**成功了，不代表我们的 UserOp 成功。
    # EntryPoint 会 catch 住内层调用的 revert，handleOps 照样返回 0x1。
    # 真正的成败在下面的 UserOperationEvent 里。
    raise AppError.new("Transaction failed on chain") unless receipt["status"] == "0x1"

    # 必须由 4337 EntryPoint 提交，排除任意普通成功交易的 hash
    to_addr = receipt["to"].to_s.downcase
    raise AppError.new("回执非 4337 EntryPoint 交易，拒绝确认") unless to_addr == ENTRY_POINT_V07

    logs = receipt["logs"] || []
    padded_safe = "0x#{"0" * 24}#{safe.sub(/\A0x/, "")}"

    # 回执必须与本 Safe 绑定：执行过程中 Safe 会发出自身事件（log.address == safe），
    # 或 EntryPoint 的 UserOperationEvent 以 safe 作为 sender（topic 含左补零的 safe 地址）。
    involves_safe = logs.any? do |log|
      addr = log["address"].to_s.downcase
      topics = (log["topics"] || []).map { |t| t.to_s.downcase }
      addr == safe || topics.include?(padded_safe)
    end
    raise AppError.new("回执未涉及本多签数字身份，拒绝确认") unless involves_safe

    # 打包交易成功不等于这笔 UserOp 成功 —— 见 UserOpReceipt。
    begin
      UserOpReceipt.assert_succeeded!(logs, padded_safe, user_op_hash)
    rescue UserOpReceipt::NotFound, UserOpReceipt::Reverted => e
      raise AppError.new("#{e.message}，拒绝确认")
    end
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

    # 发起人信息
    proposer = User.find_by(id: tx.proposer_id)
    proposer_info = if proposer
      { id: proposer.id, address: proposer.evm_chain_active_key, name: proposer.handle || proposer.phone }
    else
      { id: tx.proposer_id, address: nil, name: nil }
    end

    data = {
      id: tx.id,
      wallet_id: tx.wallet_id,
      proposer_id: tx.proposer_id,
      proposer: proposer_info,
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
      memo: tx.memo,
      sender_note: tx.sender_note,
      executor_id: tx.executor_id,
      gas_used: tx.gas_used.to_s,
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
