class WalletOwner < ApplicationRecord
  belongs_to :wallet
  belongs_to :user, optional: true

  validates :owner_address, presence: true
  validates :owner_address, uniqueness: { scope: :wallet_id, case_sensitive: false }

  before_create :set_tsid_id
  before_save :normalize_address

  private

  def set_tsid_id
    self.id = Tsid::Generator.new.generate
  end

  def normalize_address
    self.owner_address = owner_address.downcase if owner_address
  end
end
