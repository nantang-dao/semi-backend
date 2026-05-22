class SafeOwner < ApplicationRecord
  belongs_to :safe_wallet
  belongs_to :user, optional: true

  validates :evm_address, presence: true
  validates :added_at, presence: true

  before_create :set_tsid_id
  before_create :normalize_address

  scope :active, -> { where(removed_at: nil) }

  def remove!
    update!(removed_at: Time.current)
  end

  private

  def set_tsid_id
    self.id = Tsid::Generator.new.generate
  end

  def normalize_address
    self.evm_address = evm_address.downcase if evm_address.present?
  end
end
