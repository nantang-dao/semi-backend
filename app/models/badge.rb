class Badge < ApplicationRecord
  STATUSES = %w[pending accepted rejected].freeze

  belongs_to :badge_class, primary_key: "class_id", foreign_key: "class_id", optional: true

  validates :badge_id, presence: true, uniqueness: true
  validates :class_id, :wallet_address, :chain_id, presence: true
  validates :status, inclusion: { in: STATUSES }

  scope :owned, -> { where(status: "accepted") }
  scope :pending, -> { where(status: "pending") }
  scope :for_wallet, ->(address, chain_id) {
    where(wallet_address_lower: address.to_s.downcase, chain_id: chain_id)
  }

  before_create :set_tsid_id

  private

  def set_tsid_id
    self.id = Tsid::Generator.new.generate
  end
end
