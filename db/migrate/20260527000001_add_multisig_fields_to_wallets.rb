class AddMultisigFieldsToWallets < ActiveRecord::Migration[8.0]
  def change
    add_column :wallets, :threshold, :integer, default: 1, null: false
    add_column :wallets, :chain_id, :integer
  end
end
