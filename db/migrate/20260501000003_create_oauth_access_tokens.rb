class CreateOauthAccessTokens < ActiveRecord::Migration[8.0]
  def change
    create_table :oauth_access_tokens do |t|
      t.string   :token,          null: false
      t.string   :user_id,        null: false
      t.bigint   :application_id, null: false
      t.jsonb    :scopes,         null: false, default: []
      t.datetime :expires_at,     null: false
      t.datetime :revoked_at
      t.timestamps
    end
    add_index :oauth_access_tokens, :token, unique: true
    add_index :oauth_access_tokens, :user_id
    add_index :oauth_access_tokens, :application_id
    add_foreign_key :oauth_access_tokens, :users, column: :user_id
    add_foreign_key :oauth_access_tokens, :oauth_applications, column: :application_id
  end
end
