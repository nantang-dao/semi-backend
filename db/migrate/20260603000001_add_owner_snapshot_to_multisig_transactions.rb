class AddOwnerSnapshotToMultisigTransactions < ActiveRecord::Migration[7.0]
  def change
    add_column :multisig_transactions, :owner_snapshot, :jsonb, null: true, default: nil
  end
end
