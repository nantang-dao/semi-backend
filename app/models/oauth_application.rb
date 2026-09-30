class OauthApplication < ApplicationRecord
  belongs_to :owner, class_name: "User", foreign_key: :owner_id
  has_many :oauth_authorization_codes, foreign_key: :application_id, dependent: :destroy
  has_many :oauth_access_tokens, foreign_key: :application_id, dependent: :destroy
  has_many :oauth_refresh_tokens, foreign_key: :application_id, dependent: :destroy
  has_many :oauth_grants, foreign_key: :application_id, dependent: :destroy

  validates :name, presence: true
  validates :client_id, presence: true, uniqueness: true
  validates :client_secret_digest, presence: true
  validates :status, inclusion: { in: %w[draft active disabled] }
  validate :redirect_uris_must_be_valid

  before_validation :generate_client_id, on: :create
  before_validation :normalize_redirect_uris

  VALID_SCOPES = %w[openid profile wallet token:read].freeze

  MAX_REDIRECT_URIS = 10
  MAX_REDIRECT_URI_LENGTH = 2048

  # 回调地址的规则。同意页会把浏览器跳到这个地址，所以协议必须限定为 http(s)：
  # 曾经可以登记 `javascript:…`，用户点「授权」或「拒绝」就在 semi.im 上执行脚本。
  # 返回 nil 表示合法，否则返回原因。
  def self.redirect_uri_error(uri)
    uri = uri.to_s
    return "is too long" if uri.length > MAX_REDIRECT_URI_LENGTH
    return "must not contain whitespace" if uri.match?(/\s/)

    parsed = URI.parse(uri)
    return "must start with https:// or http://" unless %w[http https].include?(parsed.scheme&.downcase)
    return "must have a host" if parsed.host.blank?
    return "must not contain credentials" if parsed.userinfo.present?
    return "must not contain a fragment (#)" unless parsed.fragment.nil?

    nil
  rescue URI::InvalidURIError
    "is not a valid URL"
  end

  def self.create_with_secret(attrs)
    raw_secret = SecureRandom.hex(32)
    app = new(attrs)
    app.client_secret_digest = BCrypt::Password.create(raw_secret)
    app.save!
    [ app, raw_secret ]
  end

  # 精确匹配已登记的地址。登记时已校验过，这里再查一次规则，挡住校验上线前存进去的记录。
  def redirect_uri_allowed?(uri)
    redirect_uris.include?(uri) && self.class.redirect_uri_error(uri).nil?
  end

  def scopes_allowed?(requested)
    (Array(requested) - allowed_scopes).empty?
  end

  private

  # 接受数组，也接受按行分隔的字符串（开发者后台是每行一个）；去空白、去空行、去重。
  def normalize_redirect_uris
    self.redirect_uris = Array(redirect_uris)
      .flat_map { |u| u.to_s.split(/\r?\n/) }
      .map(&:strip)
      .reject(&:blank?)
      .uniq
  end

  def redirect_uris_must_be_valid
    if redirect_uris.empty?
      errors.add(:redirect_uris, "must include at least one URL")
    elsif redirect_uris.size > MAX_REDIRECT_URIS
      errors.add(:redirect_uris, "can include at most #{MAX_REDIRECT_URIS} URLs")
    end
    redirect_uris.each do |uri|
      reason = self.class.redirect_uri_error(uri)
      errors.add(:redirect_uris, "#{uri.truncate(80)} #{reason}") if reason
    end
  end

  def generate_client_id
    self.client_id ||= "semi_#{SecureRandom.hex(16)}"
  end
end
