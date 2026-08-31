class BadgeClass < ApplicationRecord
  has_many :badges, primary_key: "class_id", foreign_key: "class_id", dependent: :restrict_with_error

  validates :class_id, presence: true, uniqueness: true
  validates :chain_id, :profile_id, :wallet_address, :badge_contract_address, presence: true

  scope :for_wallet, ->(address, chain_id) {
    where(wallet_address_lower: address.to_s.downcase, chain_id: chain_id)
  }

  before_create :set_tsid_id

  private

  def set_tsid_id
    self.id = Tsid::Generator.new.generate
  end
end
