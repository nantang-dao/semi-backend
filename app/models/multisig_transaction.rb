class MultisigTransaction < ApplicationRecord
  belongs_to :wallet
  belongs_to :proposer, class_name: "User", foreign_key: "proposer_id"
  has_many :multisig_signatures, dependent: :destroy
  belongs_to :replaced_tx, class_name: "MultisigTransaction", foreign_key: "replaces_tx_id", optional: true

  STATUSES = %w[queued signing ready executing executed failed withdrawn superseded expired].freeze
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

  # 构建提案时的 owner 快照（所有 owner 均为 signed: false）
  def self.build_owner_snapshot(wallet)
    owners = wallet.wallet_owners.order(:position).map do |wo|
      user = wo.user
      {
        address: wo.owner_address,
        name: user&.handle || user&.phone,
        signed: false
      }
    end
    owners
  end

  # 交易进入终态时，冻结快照：更新每个 owner 的签名状态和时间
  def freeze_owner_snapshot!
    return if owner_snapshot.blank?

    signed_addresses = multisig_signatures.pluck(:signer_address).map(&:downcase)
    signed_at_map = multisig_signatures.map { |s| [s.signer_address.downcase, s.created_at] }.to_h

    updated = owner_snapshot.map do |entry|
      addr = entry["address"].to_s.downcase
      if signed_addresses.include?(addr)
        entry.merge("signed" => true, "signed_at" => signed_at_map[addr]&.iso8601)
      else
        entry.merge("signed" => false)
      end
    end

    update_column(:owner_snapshot, updated)
  end

  private

  def set_tsid_id
    self.id = Tsid::Generator.new.generate
  end
end
