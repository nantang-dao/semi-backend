class CreateMultisigSignatures < ActiveRecord::Migration[8.0]
  def change
    create_table :multisig_signatures, id: false do |t|
      t.string :multisig_transaction_id, null: false
      t.string :signer_address, null: false
      t.text :signature, null: false

      t.timestamps
    end

    add_index :multisig_signatures, [ :multisig_transaction_id, :signer_address ], unique: true, name: "idx_multisig_sigs_unique"
    add_index :multisig_signatures, :multisig_transaction_id
  end
end
