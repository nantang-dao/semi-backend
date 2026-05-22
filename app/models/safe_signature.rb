class SafeSignature < ApplicationRecord
  belongs_to :safe_transaction
  belongs_to :signer, class_name: "User", optional: true

  validates :signer_address, presence: true
  validates :signature, presence: true
  validates :signed_at, presence: true
  validate :signer_is_active_owner

  before_create :set_tsid_id
  before_create :normalize_address
  after_create :promote_transaction

  private

  def set_tsid_id
    self.id = Tsid::Generator.new.generate
  end

  def normalize_address
    self.signer_address = signer_address.downcase if signer_address.present?
  end

  def signer_is_active_owner
    return if signer_address.blank?
    wallet = safe_transaction&.safe_wallet
    return unless wallet
    unless wallet.active_owners.exists?(evm_address: signer_address.downcase)
      errors.add(:signer_address, "is not an active owner of this Safe")
    end
  end

  def promote_transaction
    safe_transaction.check_and_promote!
  end
end
