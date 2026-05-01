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

  before_validation :generate_client_id, on: :create

  VALID_SCOPES = %w[openid profile wallet token:read].freeze

  def self.create_with_secret(attrs)
    raw_secret = SecureRandom.hex(32)
    app = new(attrs)
    app.client_secret_digest = BCrypt::Password.create(raw_secret)
    app.save!
    [ app, raw_secret ]
  end

  def redirect_uri_allowed?(uri)
    redirect_uris.include?(uri)
  end

  def scopes_allowed?(requested)
    (Array(requested) - allowed_scopes).empty?
  end

  private

  def generate_client_id
    self.client_id ||= "semi_#{SecureRandom.hex(16)}"
  end
end
