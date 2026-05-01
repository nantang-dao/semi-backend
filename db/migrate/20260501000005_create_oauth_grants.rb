class CreateOauthGrants < ActiveRecord::Migration[8.0]
  def change
    create_table :oauth_grants do |t|
      t.string :user_id,        null: false
      t.bigint :application_id, null: false
      t.jsonb  :scopes,         null: false, default: []
      t.timestamps
    end
    add_index :oauth_grants, [ :user_id, :application_id ], unique: true
    add_index :oauth_grants, :user_id
    add_foreign_key :oauth_grants, :users, column: :user_id
    add_foreign_key :oauth_grants, :oauth_applications, column: :application_id
  end
end
