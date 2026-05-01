class CreateOauthApplications < ActiveRecord::Migration[8.0]
  def change
    create_table :oauth_applications do |t|
      t.string :client_id,            null: false
      t.string :client_secret_digest, null: false
      t.string :name,                 null: false
      t.jsonb  :redirect_uris,        null: false, default: []
      t.jsonb  :allowed_scopes,       null: false, default: []
      t.string :status,               null: false, default: "draft"
      t.string :owner_id,             null: false
      t.timestamps
    end
    add_index :oauth_applications, :client_id, unique: true
    add_index :oauth_applications, :owner_id
    add_foreign_key :oauth_applications, :users, column: :owner_id
  end
end
