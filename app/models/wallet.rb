class Wallet < ApplicationRecord
  belongs_to :user
  has_many :transactions

  TYPES = %w[eoa safe watch].freeze

  def set_as_primary!
    user.wallets.where(is_primary: true).update_all(is_primary: false)
    update!(is_primary: true)
    user.update!(active_wallet_id: id)
  end

  before_create :set_tsid_id

  private

  def set_tsid_id
    self.id = Tsid::Generator.new.generate
  end
end
