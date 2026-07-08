class AddHandleRenameSupport < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :handle_changed_at, :datetime

    create_table :handle_aliases do |t|
      t.string :user_id, null: false
      t.string :alias, null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end

    add_index :handle_aliases, :alias, unique: true
    add_index :handle_aliases, :user_id
    add_foreign_key :handle_aliases, :users, column: :user_id
  end
end
