class SafeTransaction < ApplicationRecord
  belongs_to :safe_wallet
  belongs_to :proposer, class_name: "User"
  has_many :safe_signatures, dependent: :destroy

  STATUSES = %w[pending ready executed rejected expired].freeze

  validates :to_address, presence: true
  validates :nonce, presence: true
  validates :safe_tx_hash, presence: true, uniqueness: true
  validates :status, inclusion: { in: STATUSES }

  before_create :set_tsid_id

  def signatures_collected
    safe_signatures.count
  end

  def threshold_reached?
    signatures_collected >= safe_wallet.threshold
  end

  def check_and_promote!
    if threshold_reached? && status == "pending"
      update!(status: "ready")
    end
  end

  def signed_by?(evm_address)
    safe_signatures.exists?(signer_address: evm_address.downcase)
  end

  private

  def set_tsid_id
    self.id = Tsid::Generator.new.generate
  end
end
