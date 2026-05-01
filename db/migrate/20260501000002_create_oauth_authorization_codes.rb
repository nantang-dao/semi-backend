class CreateOauthAuthorizationCodes < ActiveRecord::Migration[8.0]
  def change
    create_table :oauth_authorization_codes do |t|
      t.string   :code,                  null: false
      t.string   :user_id,               null: false
      t.bigint   :application_id,        null: false
      t.jsonb    :scopes,                null: false, default: []
      t.string   :redirect_uri,          null: false
      t.string   :code_challenge,        null: false
      t.string   :code_challenge_method, null: false, default: "S256"
      t.datetime :expires_at,            null: false
      t.boolean  :used,                  null: false, default: false
      t.timestamps
    end
    add_index :oauth_authorization_codes, :code, unique: true
    add_index :oauth_authorization_codes, :user_id
    add_index :oauth_authorization_codes, :application_id
    add_foreign_key :oauth_authorization_codes, :users, column: :user_id
    add_foreign_key :oauth_authorization_codes, :oauth_applications, column: :application_id
  end
end
