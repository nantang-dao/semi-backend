class CreateWalletOwners < ActiveRecord::Migration[8.0]
  def change
    create_table :wallet_owners, id: :string do |t|
      t.string :wallet_id, null: false
      t.string :user_id
      t.string :owner_address, null: false
      t.integer :position, null: false, default: 0

      t.timestamps
    end

    add_index :wallet_owners, [ :wallet_id, :owner_address ], unique: true
    add_index :wallet_owners, :wallet_id
  end
end
