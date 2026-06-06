class AddMemoToMultisigTransactions < ActiveRecord::Migration[8.0]
  def change
    add_column :multisig_transactions, :memo, :string
    add_column :multisig_transactions, :sender_note, :string
  end
end
