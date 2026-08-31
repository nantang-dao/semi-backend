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
    # 顺手把这个用户已过期的 token 标记为已吊销。记录保留 —— 排查「我是什么
    # 时候被登出的」需要它，而且这张表的增长很慢。
    #
    # 认证那边看的是 AuthToken.usable，过期本来就已经拦住了；这一步只是让
    # 数据库里的状态和事实一致，不是安全边界。
    auth_tokens.where(disabled: false).where("expires_at <= ?", Time.current)
               .update_all(disabled: true, updated_at: Time.current)

    AuthToken.create(user: self).token
  end

  before_create :set_tsid_id

  private

  def set_tsid_id
    self.id = Tsid::Generator.new.generate
  end
end
