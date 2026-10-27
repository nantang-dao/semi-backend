# keystore v2：解密密钥由「支付码派生的一半」和服务端的 key_share 合成，服务端核对支付码之后才下发
# key_share，并限制失败次数。6 位支付码只有 10⁶ 种组合，v1 keystore 拖库或偷到登录态即可离线爆破；
# v2 把它变成在线猜测。设计与取舍见 docs/keystore.md。
#
# 客户端（semi-core keys/keystore.ts）：
#   pin_key  = PBKDF2-SHA256(支付码, salt, iterations)
#   verifier = HKDF(pin_key, info "semi-keystore-v2/verify")      → 发给服务端
#   enc_part = HKDF(pin_key, info "semi-keystore-v2/encrypt")     → 只在客户端
#   aes_key  = HKDF(enc_part ‖ key_share, salt, info "semi-keystore-v2/aes")
#
# 服务端只存 HMAC(mac_key, verifier) 和用 share_key 加密的 key_share。两把密钥由环境变量
# KEYSTORE_SERVER_SECRET 派生，不进数据库、不进备份：只拖到数据库既验证不了支付码，也解不出
# key_share。**这个变量丢了，所有 v2 用户都解不开 keystore**（只能用助记词恢复），务必另行备份。
module KeystoreVault
  class Invalid < StandardError; end

  class BadPasscode < StandardError
    attr_reader :attempts_left

    def initialize(attempts_left)
      @attempts_left = attempts_left
      super("Incorrect passcode")
    end
  end

  class Locked < StandardError
    attr_reader :locked_until

    def initialize(locked_until)
      @locked_until = locked_until
      super("Too many incorrect passcodes, try again later")
    end
  end

  # 连续错 50 次锁 24 小时（期满自动解锁、重新计数）：一天最多猜 50 次，一年约 1.8% 猜中 6 位数字。
  # 2026-10-01 从 10 次放宽到 50 次，给记不清支付码的用户留余地。
  # 锁定期间正确的支付码也不放行，否则锁定挡不住攻击者。
  MAX_FAILED_ATTEMPTS = 50
  LOCK_DURATION = 24.hours
  # update_keystore 的签名有效期。issued_at 还必须晚于上一次更新，旧签名不能重放回旧 keystore。
  UPDATE_WINDOW = 10.minutes
  MIN_ITERATIONS = 100_000
  KEY_VERSION = "k1"
  HEX32 = /\A[0-9a-f]{64}\z/

  module_function

  def server_secret
    @server_secret ||= begin
      hex = ENV["KEYSTORE_SERVER_SECRET"].to_s
      if hex.match?(/\A[0-9a-fA-F]{64}\z/)
        [ hex ].pack("H*")
      elsif Rails.env.production?
        raise "KEYSTORE_SERVER_SECRET must be set to 32 bytes of hex (openssl rand -hex 32)"
      else
        Digest::SHA256.digest("semi-dev-only-keystore-server-secret")
      end
    end
  end

  def subkey(info)
    OpenSSL::KDF.hkdf(server_secret, salt: "", info: info, length: 32, hash: "SHA256")
  end

  # ---- 读 ----

  # encrypted_keys 是 jsonb，前端一直传 JSON 字符串，所以库里是 jsonb 字符串（生产 267 行全是）
  def parse(raw)
    return raw if raw.is_a?(Hash)
    return nil if raw.blank?
    JSON.parse(raw)
  rescue JSON::ParserError
    nil
  end

  def version(user)
    return 2 if user.keystore_verifier_mac.present?
    user.encrypted_keys.present? ? 1 : nil
  end

  # 客户端算 verifier 要用 salt 和迭代次数（keystore 里本来就是明文）
  def public_params(user)
    crypto = parse(user.encrypted_keys)&.dig("crypto") || {}
    { salt: crypto["salt"], iterations: crypto["iterations"], hash: crypto["hash"] }
  end

  # ---- 写 ----

  def validate_v2!(encrypted_keys, verifier, key_share)
    raise Invalid, "verifier must be 32 bytes of hex" unless verifier.to_s.match?(HEX32)
    raise Invalid, "key_share must be 32 bytes of hex" unless key_share.to_s.match?(HEX32)
    raise Invalid, "encrypted_keys must be a JSON string" unless encrypted_keys.is_a?(String)

    ks = parse(encrypted_keys)
    crypto = ks.is_a?(Hash) ? ks["crypto"] : nil
    valid = ks.is_a?(Hash) && ks["version"] == 2 && crypto.is_a?(Hash) &&
      crypto["keyShare"] == true && crypto["kdf"] == "pbkdf2" && crypto["hash"] == "SHA-256" &&
      crypto["cipher"] == "aes-gcm" && crypto["iterations"].is_a?(Integer) && crypto["iterations"] >= MIN_ITERATIONS &&
      crypto["salt"].to_s.match?(/\A[0-9a-f]{32}\z/) && crypto["iv"].to_s.match?(/\A[0-9a-f]{24}\z/) &&
      crypto["ciphertext"].to_s.match?(%r{\A[A-Za-z0-9+/]+=*\z})
    raise Invalid, "encrypted_keys is not a v2 keystore" unless valid
  end

  # 只赋值不保存，由调用方和其他字段一起 save
  def assign_v2(user, encrypted_keys:, verifier:, key_share:)
    user.encrypted_keys = encrypted_keys
    user.keystore_verifier_mac = mac(user.id, verifier)
    user.key_share_ciphertext = encrypt_share(user.id, key_share)
    user.keystore_failed_attempts = 0
    user.keystore_locked_until = nil
  end

  # ---- 解锁 ----

  # 返回 key_share（hex）。错了计数，满 MAX_FAILED_ATTEMPTS 次锁定；行锁防止并发请求绕过计数。
  # 异常要在事务提交之后再抛：在 with_lock 里抛会回滚，失败计数就白记了。
  def unlock!(user, verifier)
    raise Invalid, "verifier must be 32 bytes of hex" unless verifier.to_s.match?(HEX32)

    outcome = user.with_lock do
      if user.keystore_locked_until&.future?
        Locked.new(user.keystore_locked_until)
      elsif ActiveSupport::SecurityUtils.secure_compare(mac(user.id, verifier), user.keystore_verifier_mac.to_s)
        user.update!(keystore_failed_attempts: 0, keystore_locked_until: nil)
        decrypt_share(user.id, user.key_share_ciphertext)
      elsif (attempts = user.keystore_failed_attempts + 1) >= MAX_FAILED_ATTEMPTS
        user.update!(keystore_failed_attempts: 0, keystore_locked_until: LOCK_DURATION.from_now)
        Locked.new(user.keystore_locked_until)
      else
        user.update!(keystore_failed_attempts: attempts, keystore_locked_until: nil)
        BadPasscode.new(MAX_FAILED_ATTEMPTS - attempts)
      end
    end
    raise outcome if outcome.is_a?(StandardError)
    outcome
  end

  # ---- 更新（v1 升级、以后改支付码）----

  # 前端 utils/keystore_session.ts 的 keystoreUpdateMessage 签的就是这句话，两边必须逐字相同。
  def update_message(user_id, issued_at, encrypted_keys, verifier, key_share)
    digest = Digest::SHA256.hexdigest("#{encrypted_keys}\n#{verifier}\n#{key_share}")
    "Semi: update keystore of account #{user_id} at #{issued_at} sha256:#{digest}"
  end

  def verify_update!(user, issued_at:, public_key:, signature:, encrypted_keys:, verifier:, key_share:)
    raise Invalid, "no signing key is bound to this account" if user.evm_chain_active_key.blank?
    raise Invalid, "issued_at must be unix seconds" unless issued_at.to_s.match?(/\A\d{1,12}\z/)

    at = Time.at(issued_at.to_i)
    raise Invalid, "issued_at is too old or in the future" if (Time.current - at).abs > UPDATE_WINDOW
    if user.keystore_updated_at && at <= user.keystore_updated_at
      raise Invalid, "issued_at must be later than the last keystore update"
    end

    begin
      address = WalletBinding.address_from_public_key(public_key)
    rescue WalletBinding::InvalidProof => e
      raise Invalid, e.message
    end
    raise Invalid, "public_key does not belong to this account's signing key" unless address == user.evm_chain_active_key.downcase

    message = update_message(user.id, issued_at.to_i, encrypted_keys, verifier, key_share)
    raise Invalid, "signature does not match" unless WalletBinding.signature_valid?(public_key, message, signature)
    at
  end

  # ---- 内部 ----

  # 带上 user_id：同一个支付码在不同账户下的 verifier 本来就不同（salt 不同），这里再防一次挪用
  def mac(user_id, verifier)
    "#{KEY_VERSION}:" + OpenSSL::HMAC.hexdigest("SHA256", subkey("semi-keystore/mac"), "#{user_id}:#{verifier}")
  end

  def encrypt_share(user_id, key_share)
    cipher = OpenSSL::Cipher.new("aes-256-gcm").encrypt
    cipher.key = subkey("semi-keystore/share")
    iv = cipher.random_iv
    cipher.auth_data = "user:#{user_id}"
    ct = cipher.update([ key_share ].pack("H*")) + cipher.final
    "#{KEY_VERSION}:" + Base64.strict_encode64(iv + cipher.auth_tag + ct)
  end

  def decrypt_share(user_id, stored)
    version, payload = stored.to_s.split(":", 2)
    raise Invalid, "unknown key_share key version" unless version == KEY_VERSION
    raw = Base64.strict_decode64(payload)
    cipher = OpenSSL::Cipher.new("aes-256-gcm").decrypt
    cipher.key = subkey("semi-keystore/share")
    cipher.iv = raw[0, 12]
    cipher.auth_tag = raw[12, 16]
    cipher.auth_data = "user:#{user_id}"
    (cipher.update(raw[28..]) + cipher.final).unpack1("H*")
  end
end
