class SafeController < ApplicationController
  before_action :require_auth
  before_action :set_safe_wallet, only: [ :show, :update, :destroy, :list_transactions, :create_transaction, :show_transaction, :cancel_transaction, :sign_transaction, :unsign_transaction, :list_owners ]

  # GET /safe/wallets
  def index
    wallets = current_user.safe_wallets
      .or(SafeWallet.where(id: SafeOwner.where(user_id: current_user.id).select(:safe_wallet_id)))
      .where(status: "active")
      .order(created_at: :desc)

    render json: { result: "ok", wallets: serialize_wallets(wallets) }
  end

  # POST /safe/wallets
  def create
    owners_params = params[:owners] || []

    safe = SafeWallet.new(
      creator:   current_user,
      name:      params[:name],
      chain_id:  params[:chain_id],
      threshold: params[:threshold],
      description: params[:description]
    )

    unless safe.valid?
      return render json: { error: safe.errors.full_messages.first }, status: :unprocessable_entity
    end

    unless params[:threshold].to_i >= 1
      return render json: { error: "Threshold must be at least 1" }, status: :unprocessable_entity
    end

    # Build owner list — creator always included
    owner_entries = build_owner_entries(owners_params)

    # Ensure creator is in the list
    creator_address = current_user.evm_chain_address&.downcase
    unless owner_entries.any? { |o| o[:evm_address] == creator_address }
      owner_entries.unshift({ evm_address: creator_address, user_id: current_user.id, label: current_user.handle || "Me" })
    end

    if owner_entries.size < params[:threshold].to_i
      return render json: { error: "Threshold cannot exceed number of owners" }, status: :unprocessable_entity
    end

    ActiveRecord::Base.transaction do
      safe.save!
      owner_entries.each do |entry|
        SafeOwner.create!(
          safe_wallet: safe,
          user_id:     entry[:user_id],
          evm_address: entry[:evm_address],
          label:       entry[:label],
          added_at:    Time.current
        )
      end
    end

    render json: { result: "ok", wallet: serialize_wallet(safe) }, status: :created
  end

  # GET /safe/wallets/:id
  def show
    render json: { result: "ok", wallet: serialize_wallet(@safe, include_owners: true) }
  end

  # DELETE /safe/wallets/:id
  def destroy
    raise AuthError.new("Only creator can archive this Safe") unless @safe.creator_id == current_user.id
    @safe.update!(status: "archived")
    render json: { result: "ok" }
  end

  # GET /safe/wallets/:id/owners
  def list_owners
    owners = @safe.active_owners.order(:added_at)
    render json: { result: "ok", owners: serialize_owners(owners) }
  end

  # GET /safe/wallets/:id/transactions
  def list_transactions
    txs = @safe.safe_transactions.order(created_at: :desc)
    txs = txs.where(status: params[:status]) if params[:status].present?
    render json: { result: "ok", transactions: serialize_transactions(txs) }
  end

  # POST /safe/wallets/:id/transactions
  def create_transaction
    nonce = params[:nonce] || next_nonce(@safe)

    tx = SafeTransaction.new(
      safe_wallet:  @safe,
      proposer:     current_user,
      to_address:   params[:to],
      value:        params[:value] || 0,
      data:         params[:data] || "0x",
      operation:    params[:operation] || 0,
      nonce:        nonce,
      safe_tx_hash: params[:safe_tx_hash],
      description:  params[:description],
      expires_at:   params[:expires_hours].present? ? params[:expires_hours].to_i.hours.from_now : nil
    )

    unless tx.valid?
      return render json: { error: tx.errors.full_messages.first }, status: :unprocessable_entity
    end

    tx.save!
    render json: { result: "ok", transaction: serialize_transaction(tx) }, status: :created
  end

  # GET /safe/wallets/:id/transactions/:tx_id
  def show_transaction
    tx = @safe.safe_transactions.find_by(id: params[:tx_id])
    raise AppError.new("Transaction Not Found") unless tx
    render json: { result: "ok", transaction: serialize_transaction(tx, include_signatures: true) }
  end

  # DELETE /safe/wallets/:id/transactions/:tx_id
  def cancel_transaction
    tx = @safe.safe_transactions.find_by(id: params[:tx_id])
    raise AppError.new("Transaction Not Found") unless tx
    raise AuthError.new("Only proposer can cancel") unless tx.proposer_id == current_user.id
    raise AppError.new("Cannot cancel a transaction that is already #{tx.status}") unless tx.status == "pending"

    tx.update!(status: "rejected")
    render json: { result: "ok" }
  end

  # POST /safe/wallets/:id/transactions/:tx_id/sign
  def sign_transaction
    tx = @safe.safe_transactions.find_by(id: params[:tx_id])
    raise AppError.new("Transaction Not Found") unless tx
    raise AppError.new("Transaction is not pending") unless %w[pending ready].include?(tx.status)

    signer_address = params[:signer_address]&.downcase
    raise AppError.new("signer_address required") if signer_address.blank?
    raise AppError.new("signature required") if params[:signature].blank?

    # Verify the signer_address belongs to current user or is an owner without Semi account
    owner = @safe.active_owners.find_by(evm_address: signer_address)
    raise AuthError.new("Not an active owner of this Safe") unless owner
    if owner.user_id.present? && owner.user_id != current_user.id
      raise AuthError.new("This address belongs to a different user")
    end

    if tx.signed_by?(signer_address)
      return render json: { error: "Already signed" }, status: :unprocessable_entity
    end

    sig = SafeSignature.create!(
      safe_transaction: tx,
      signer_id:        current_user.id,
      signer_address:   signer_address,
      signature:        params[:signature],
      signed_at:        Time.current
    )

    tx.reload
    render json: { result: "ok", signatures_collected: tx.signatures_collected, threshold: @safe.threshold, status: tx.status }
  end

  # DELETE /safe/wallets/:id/transactions/:tx_id/sign
  def unsign_transaction
    tx = @safe.safe_transactions.find_by(id: params[:tx_id])
    raise AppError.new("Transaction Not Found") unless tx
    raise AppError.new("Cannot unsign a #{tx.status} transaction") unless tx.status == "pending"

    signer_address = current_user.evm_chain_address&.downcase
    sig = tx.safe_signatures.find_by(signer_id: current_user.id)
    raise AppError.new("No signature found") unless sig

    sig.destroy!
    render json: { result: "ok" }
  end

  # PATCH /safe/wallets/:id/set_safe_address
  def set_safe_address
    raise AuthError.new("Only creator can set Safe address") unless @safe.creator_id == current_user.id
    @safe.update!(safe_address: params[:safe_address])
    render json: { result: "ok", safe_address: @safe.safe_address }
  end

  private

  def require_auth
    raise AuthError.new("Not authenticated") unless current_user
  end

  def set_safe_wallet
    @safe = SafeWallet.find_by(id: params[:id])
    raise AppError.new("Safe wallet not found") unless @safe

    # Must be a member or creator
    is_member = @safe.creator_id == current_user.id ||
      @safe.active_owners.exists?(user_id: current_user.id)
    raise AuthError.new("Not a member of this Safe") unless is_member
  end

  def build_owner_entries(owners_params)
    owners_params.map do |o|
      evm_address = o[:evm_address]
      user_id     = o[:user_id]
      label       = o[:label]

      if user_id.present? && evm_address.blank?
        u = User.find_by(id: user_id)
        evm_address = u&.evm_chain_address
        label ||= u&.handle
      end

      raise AppError.new("Owner missing evm_address") if evm_address.blank?

      { evm_address: evm_address.downcase, user_id: user_id, label: label }
    end
  end

  def next_nonce(safe)
    (safe.safe_transactions.maximum(:nonce) || -1) + 1
  end

  def serialize_wallets(wallets)
    wallets.map { |w| serialize_wallet(w) }
  end

  def serialize_wallet(w, include_owners: false)
    data = {
      id:           w.id,
      name:         w.name,
      description:  w.description,
      safe_address: w.safe_address,
      chain_id:     w.chain_id,
      threshold:    w.threshold,
      owners_count: w.active_owners.count,
      status:       w.status,
      creator_id:   w.creator_id,
      created_at:   w.created_at
    }
    data[:owners] = serialize_owners(w.active_owners.order(:added_at)) if include_owners
    data
  end

  def serialize_owners(owners)
    owners.map do |o|
      {
        id:          o.id,
        evm_address: o.evm_address,
        label:       o.label,
        user_id:     o.user_id,
        handle:      o.user&.handle,
        added_at:    o.added_at
      }
    end
  end

  def serialize_transactions(txs)
    txs.map { |tx| serialize_transaction(tx) }
  end

  def serialize_transaction(tx, include_signatures: false)
    data = {
      id:                   tx.id,
      safe_wallet_id:       tx.safe_wallet_id,
      proposer_id:          tx.proposer_id,
      proposer_handle:      tx.proposer&.handle,
      to_address:           tx.to_address,
      value:                tx.value.to_s,
      data:                 tx.data,
      operation:            tx.operation,
      nonce:                tx.nonce,
      safe_tx_hash:         tx.safe_tx_hash,
      description:          tx.description,
      status:               tx.status,
      signatures_collected: tx.signatures_collected,
      threshold:            tx.safe_wallet.threshold,
      on_chain_tx_hash:     tx.on_chain_tx_hash,
      expires_at:           tx.expires_at,
      executed_at:          tx.executed_at,
      created_at:           tx.created_at
    }
    if include_signatures
      data[:signatures] = tx.safe_signatures.map do |s|
        { id: s.id, signer_address: s.signer_address, signer_id: s.signer_id, handle: s.signer&.handle, signature: s.signature, signed_at: s.signed_at }
      end
    end
    data
  end
end
