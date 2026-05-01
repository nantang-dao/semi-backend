class OauthAuthorizationCode < ApplicationRecord
  belongs_to :user
  belongs_to :oauth_application, foreign_key: :application_id

  validates :code, presence: true, uniqueness: true
  validates :code_challenge, presence: true
  validates :redirect_uri, presence: true

  scope :valid, -> { where(used: false).where("expires_at > ?", Time.current) }

  before_validation :generate_code, on: :create

  TTL = 60.seconds

  def verify_pkce!(verifier)
    digest = Base64.urlsafe_encode64(Digest::SHA256.digest(verifier), padding: false)
    raise AppError.new("Invalid code_verifier") unless digest == code_challenge
  end

  private

  def generate_code
    loop do
      self.code = SecureRandom.hex(32)
      self.expires_at ||= TTL.from_now
      break unless OauthAuthorizationCode.exists?(code: self.code)
    end
  end
end
