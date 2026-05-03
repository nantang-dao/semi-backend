class OauthAccessToken < ApplicationRecord
  belongs_to :user
  belongs_to :oauth_application, foreign_key: :application_id
  has_one :oauth_refresh_token, foreign_key: :access_token_id, dependent: :destroy

  validates :token, presence: true, uniqueness: true

  before_validation :generate_token, on: :create

  TTL = 10.years

  def self.issue(user:, application:, scopes:)
    create!(
      user: user,
      oauth_application: application,
      scopes: scopes,
      expires_at: TTL.from_now
    )
  end

  def active?
    revoked_at.nil? && expires_at > Time.current
  end

  def revoke!
    update!(revoked_at: Time.current)
    oauth_refresh_token&.revoke!
  end

  private

  def generate_token
    loop do
      self.token = SecureRandom.hex(32)
      break unless OauthAccessToken.exists?(token: self.token)
    end
  end
end
