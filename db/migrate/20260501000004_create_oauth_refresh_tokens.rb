class CreateOauthRefreshTokens < ActiveRecord::Migration[8.0]
  def change
    create_table :oauth_refresh_tokens do |t|
      t.string   :token,           null: false
      t.string   :user_id,         null: false
      t.bigint   :application_id,  null: false
      t.bigint   :access_token_id, null: false
      t.datetime :expires_at,      null: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :oauth_refresh_tokens, :token, unique: true
    add_index :oauth_refresh_tokens, :user_id
    add_index :oauth_refresh_tokens, :access_token_id
    add_foreign_key :oauth_refresh_tokens, :users, column: :user_id
    add_foreign_key :oauth_refresh_tokens, :oauth_applications, column: :application_id
    add_foreign_key :oauth_refresh_tokens, :oauth_access_tokens, column: :access_token_id
  end
end
