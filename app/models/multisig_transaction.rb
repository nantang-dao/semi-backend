class MultisigTransaction < ApplicationRecord
  belongs_to :wallet
  belongs_to :proposer, class_name: "User", foreign_key: "proposer_id"
  has_many :multisig_signatures, dependent: :destroy
  belongs_to :replaced_tx, class_name: "MultisigTransaction", foreign_key: "replaces_tx_id", optional: true
  belongs_to :executor, class_name: "User", foreign_key: "executor_id", optional: true

  STATUSES = %w[queued signing ready executing confirming executed failed withdrawn superseded expired].freeze
  TERMINAL_STATUSES = %w[executed failed withdrawn superseded expired].freeze
  TX_TYPES = %w[transfer erc20_transfer add_owner remove_owner change_threshold cancel replace_owner].freeze

  scope :active, -> { where(status: %w[queued signing ready]) }
  scope :in_queue_order, -> { where.not(queue_position: nil).order(queue_position: :asc) }
  scope :competing, -> { where(queue_position: nil).where.not(replaces_tx_id: nil) }
  scope :history, -> { where(status: TERMINAL_STATUSES) }

  before_create :set_tsid_id

  def signature_count
    multisig_signatures.count
  end

  def signatures_data
    # 批量查找所有签名者对应的 User，避免 N+1
    addresses = multisig_signatures.map(&:signer_address).map(&:downcase)
    users_by_addr = User.where("LOWER(evm_chain_active_key) IN (?)", addresses)
                        .index_by { |u| u.evm_chain_active_key.to_s.downcase }

    multisig_signatures.order(:signer_address).map do |sig|
      addr = sig.signer_address.downcase
      user = users_by_addr[addr]
      {
        signer_address: sig.signer_address,
        signature: sig.signature,
        signer_handle: user&.handle,
        signer_phone: user&.phone,
        signer_image_url: user&.image_url
      }
    end
  end

  def reached_threshold?
    signature_count >= threshold_at_creation
  end

  def front_of_queue?(wallet_queue)
    min_pos = wallet_queue.minimum(:queue_position)
    queue_position == min_pos
  end

  def competing_replacement?
    replaces_tx_id.present? && queue_position.nil?
  end

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  # 交易进入终态时，从当前钱包 owner 列表 + 签名记录构建快照
  # 这样快照反映的是执行那一刻的真实权限状态
  # 同时保存发起人信息，确保历史可追溯
  def freeze_owner_snapshot!
    signed_addresses = multisig_signatures.pluck(:signer_address).map(&:downcase)
    signed_at_map = multisig_signatures.map { |s| [s.signer_address.downcase, s.created_at] }.to_h

    owners = wallet.wallet_owners.order(:position).map do |wo|
      addr = wo.owner_address.downcase
      user = wo.user
      entry = {
        address: wo.owner_address,
        name: user&.handle || user&.phone,
        signed: signed_addresses.include?(addr)
      }
      if signed_addresses.include?(addr)
        entry[:signed_at] = signed_at_map[addr]&.iso8601
      end
      entry
    end

    # 保存发起人信息
    proposer_user = User.find_by(id: proposer_id)
    proposer_entry = if proposer_user
      { id: proposer_id, address: proposer_user.evm_chain_active_key, name: proposer_user.handle || proposer_user.phone }
    else
      { id: proposer_id }
    end

    update_column(:owner_snapshot, { owners: owners, proposer: proposer_entry })
  end

  private

  def set_tsid_id
    self.id = Tsid::Generator.new.generate
  end
end
