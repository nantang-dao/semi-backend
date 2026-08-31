class AuthToken < ApplicationRecord
  belongs_to :user, optional: true
  validates :token, presence: true, uniqueness: true
  before_validation :generate_token, on: :create
  before_validation :set_expiry, on: :create

  # token 的有效期。与前端 cookie 的 365 天一致 —— 两边同时到期，
  # 不会出现「cookie 还在但服务端已拒」或反过来的错位。
  LIFETIME = 1.year

  # 能用来认证的 token：没被吊销，也没过期。
  # current_user 只查这个 scope —— disabled 这个列早就存在，但一直没有任何
  # 地方检查它，等于一个没接线的开关。
  scope :usable, -> { where(disabled: false).where("expires_at > ?", Time.current) }

  def usable?
    !disabled? && expires_at.present? && expires_at > Time.current
  end

  # 登出 / 吊销。不删记录，留着以便排查「这个 token 是什么时候失效的」。
  def revoke!
    update!(disabled: true)
  end

  # last_used_at 的写入节流。
  #
  # 每个请求都写一次数据库是不可接受的开销，而这个字段的用途（找出僵尸会话、
  # 将来做滑动过期）根本不需要秒级精度。超过一小时才写。
  TOUCH_INTERVAL = 1.hour

  def touch_last_used!
    return if last_used_at.present? && last_used_at > TOUCH_INTERVAL.ago

    # update_column：跳过校验和 updated_at —— updated_at 要留给「什么时候被
    # 吊销的」，不能被每小时一次的心跳冲掉。
    update_column(:last_used_at, Time.current)
  end

  private

  def generate_token
    loop do
      self.token = SecureRandom.hex(16)
      break token unless AuthToken.exists?(token: self.token)
    end
  end

  def set_expiry
    self.expires_at ||= Time.current + LIFETIME
  end
end
