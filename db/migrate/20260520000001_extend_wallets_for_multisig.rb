class ExtendWalletsForMultisig < ActiveRecord::Migration[8.0]
  def change
    add_column :wallets, :is_primary, :boolean, default: false, null: false
    add_column :wallets, :chain_id,   :integer
    add_column :wallets, :avatar_url, :string
    add_index  :wallets, [ :user_id, :is_primary ]

    add_column :users, :active_wallet_id, :string
  end
end
