class User < ApplicationRecord
  has_many :auth_tokens
  has_many :wallets
  has_many :transactions
  has_many :handle_aliases

  RENAME_COOLDOWN = 30.days
  ALIAS_RETENTION = 90.days

  def next_rename_at
    return nil unless handle_changed_at

    handle_changed_at + RENAME_COOLDOWN
  end

  def can_rename?
    next_rename_at.nil? || next_rename_at <= Time.current
  end

  def gen_auth_token
    auth_token = AuthToken.create(user: self)
    auth_token.token
  end

  before_create :set_tsid_id

  private

  def set_tsid_id
    self.id = Tsid::Generator.new.generate
  end
end
