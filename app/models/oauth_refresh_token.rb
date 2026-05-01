class OauthRefreshToken < ApplicationRecord
  belongs_to :user
  belongs_to :oauth_application, foreign_key: :application_id
  belongs_to :oauth_access_token, foreign_key: :access_token_id

  validates :token, presence: true, uniqueness: true

  before_validation :generate_token, on: :create

  TTL = 30.days

  def self.issue(user:, application:, access_token:)
    create!(
      user: user,
      oauth_application: application,
      oauth_access_token: access_token,
      expires_at: TTL.from_now
    )
  end

  def active?
    revoked_at.nil? && expires_at > Time.current
  end

  def revoke!
    update!(revoked_at: Time.current)
  end

  # Revoke self+current access token, issue a fresh access+refresh pair.
  def rotate!
    raise AppError.new("Refresh token revoked or expired") unless active?
    revoke!
    oauth_access_token.update!(revoked_at: Time.current)
    new_access = OauthAccessToken.issue(
      user: user,
      application: oauth_application,
      scopes: oauth_access_token.scopes
    )
    new_refresh = OauthRefreshToken.issue(
      user: user,
      application: oauth_application,
      access_token: new_access
    )
    [ new_access, new_refresh ]
  end

  private

  def generate_token
    loop do
      self.token = SecureRandom.hex(32)
      break unless OauthRefreshToken.exists?(token: self.token)
    end
  end
end
