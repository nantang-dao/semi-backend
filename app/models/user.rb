class User < ApplicationRecord
  has_many :auth_tokens
  has_many :wallets
  has_many :transactions
  has_many :safe_wallets, foreign_key: :creator_id
  belongs_to :active_wallet, class_name: "Wallet", optional: true

  def gen_auth_token
    auth_token = AuthToken.create(user: self)
    auth_token.token
  end

  def primary_wallet
    active_wallet || wallets.find_by(is_primary: true) || wallets.first
  end

  before_create :set_tsid_id

  private

  def set_tsid_id
    self.id = Tsid::Generator.new.generate
  end
end