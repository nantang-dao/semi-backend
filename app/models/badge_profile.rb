class BadgeProfile < ApplicationRecord
  has_many :badge_classes, primary_key: "profile_id", foreign_key: "profile_id", dependent: :nullify

  validates :profile_id, presence: true, uniqueness: true
  validates :wallet_address, :chain_id, presence: true

  # wallet_address 参与 namehash，不能改大小写；查询走 generated 列。
  scope :for_wallet, ->(address, chain_id) {
    where(wallet_address_lower: address.to_s.downcase, chain_id: chain_id)
  }

  before_create :set_tsid_id

  private

  def set_tsid_id
    self.id = Tsid::Generator.new.generate
  end
end
