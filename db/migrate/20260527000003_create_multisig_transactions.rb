class CreateMultisigTransactions < ActiveRecord::Migration[8.0]
  def change
    create_table :multisig_transactions, id: :string do |t|
      t.string :wallet_id, null: false
      t.string :proposer_id, null: false
      t.integer :chain_id, null: false
      t.integer :queue_position
      t.string :nonce
      t.string :tx_type, null: false
      t.jsonb :call_detail, null: false, default: {}
      t.text :evm_call_data, null: false, default: ""
      t.jsonb :user_op_snapshot
      t.integer :threshold_at_creation, null: false
      t.string :replaces_tx_id
      t.string :status, null: false, default: "queued"
      t.string :tx_hash
      t.datetime :expires_at

      t.timestamps
    end

    add_index :multisig_transactions, [ :wallet_id, :status ]
    add_index :multisig_transactions, [ :wallet_id, :queue_position ]
    add_index :multisig_transactions, :wallet_id
  end
end
