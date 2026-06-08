class AddExecutorAndGasToMultisigTransactions < ActiveRecord::Migration[8.0]
  def change
    # The user who executed (the "last user" that triggered on-chain execution).
    # Gas is paid by the paymaster on-chain, but the cost is accredited to this
    # user in the DB for internal accounting.
    add_column :multisig_transactions, :executor_id, :string
    # Actual gas cost in wei (from the ERC-4337 UserOperation receipt's actualGasCost).
    add_column :multisig_transactions, :gas_used, :decimal, precision: 80, default: "0", null: false

    add_index :multisig_transactions, :executor_id
  end
end
