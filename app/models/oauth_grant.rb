class OauthGrant < ApplicationRecord
  belongs_to :user
  belongs_to :oauth_application, foreign_key: :application_id

  validates :user_id, uniqueness: { scope: :application_id }

  def covers?(requested_scopes)
    (Array(requested_scopes) - scopes).empty?
  end

  def self.upsert_for(user:, application:, scopes:)
    grant = find_or_initialize_by(user: user, oauth_application: application)
    grant.scopes = (grant.scopes + Array(scopes)).uniq
    grant.save!
    grant
  end
end
