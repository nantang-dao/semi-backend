# 登录验证码（手机短信 / 邮箱）。
#
# 6 位数字只有 10⁶ 种，安全性全靠「猜的次数有限」。曾经：旧码不作废、每发一次多一个
# 同时有效的码、猜错没有代价、发送不限频率 —— 邮箱码几分钟就能在线爆破，短信可被刷费。
# 规则见 docs/auth.md。
class VerificationToken < ApplicationRecord
  TTL = 15.minutes
  MAX_ATTEMPTS = 5
  SEND_COOLDOWN = 60.seconds # 与前端重发倒计时一致
  SENDS_PER_TARGET_PER_HOUR = 5
  SENDS_PER_TARGET_PER_DAY = 12 # 历史上单个号码一天最多发过 11 次；每码 5 次 → 每天最多猜 60 次
  SENDS_PER_IP_PER_HOUR = 30 # 历史峰值全站每小时 21 个码；留出活动现场共用 Wi-Fi 的余量

  validates :context, :code, :sent_to, presence: true

  # 生成并记下新码；同一目标之前没用掉的码一律作废，任何时刻最多一个有效码。
  # 超过频率限制抛 AppError(rate_limited)。
  def self.issue!(context:, sent_to:, ip:)
    code = SecureRandom.random_number(1_000_000).to_s.rjust(6, "0")
    transaction do
      # 同一目标的发送串行化，并发请求不能同时通过冷却检查
      connection.execute(sanitize_sql([ "SELECT pg_advisory_xact_lock(hashtext(?))", "verification:#{context}:#{sent_to}" ]))

      now = Time.current
      recent = where(context: context, sent_to: sent_to).where("created_at > ?", now - 1.day)
      if recent.where("created_at > ?", now - SEND_COOLDOWN).exists? ||
         recent.where("created_at > ?", now - 1.hour).count >= SENDS_PER_TARGET_PER_HOUR ||
         recent.count >= SENDS_PER_TARGET_PER_DAY ||
         (ip.present? && where(ip: ip).where("created_at > ?", now - 1.hour).count >= SENDS_PER_IP_PER_HOUR)
        raise AppError.new("Too many requests", code: "rate_limited")
      end

      where(context: context, sent_to: sent_to, used: false).update_all(used: true, updated_at: now)
      create!(context: context, sent_to: sent_to, code: code, ip: ip, expires_at: now + TTL)
    end
    code
  end

  # 核对并核销。只看该目标最新的一个码；每个码最多试 MAX_ATTEMPTS 次。
  # 计数和核销都用带条件的 update_all，并发请求不能多试一次，也不能把同一个码用两次。
  def self.consume!(context:, sent_to:, code:)
    token = where(context: context, sent_to: sent_to, used: false).order(created_at: :desc).first
    raise AppError.new("Invalid code", code: "invalid_code") unless token
    raise AppError.new("Code expired", code: "code_expired") if token.expires_at < Time.current

    counted = where(id: token.id, used: false).where("attempts < ?", MAX_ATTEMPTS)
                                              .update_all([ "attempts = attempts + 1, updated_at = ?", Time.current ])
    raise AppError.new("Too many attempts", code: "too_many_attempts") if counted.zero?

    unless ActiveSupport::SecurityUtils.secure_compare(token.code.to_s, code.to_s)
      raise AppError.new("Invalid code", code: "invalid_code")
    end

    used = where(id: token.id, used: false).update_all(used: true, updated_at: Time.current)
    raise AppError.new("Invalid code", code: "invalid_code") if used.zero?
  end
end
