class CreateSafeTables < ActiveRecord::Migration[8.0]
  def change
    create_table :safe_wallets, id: :string do |t|
      t.string  :name,         null: false
      t.text    :description
      t.string  :safe_address                    # nil until deployed on-chain
      t.integer :chain_id,     null: false
      t.integer :threshold,    null: false
      t.string  :creator_id,   null: false
      t.string  :status,       default: "active", null: false  # active | archived
      t.timestamps
    end
    add_index :safe_wallets, :creator_id
    add_index :safe_wallets, :safe_address

    create_table :safe_owners, id: :string do |t|
      t.string    :safe_wallet_id, null: false
      t.string    :user_id                       # nil if not a Semi user
      t.string    :evm_address,   null: false
      t.string    :label
      t.datetime  :added_at,      null: false
      t.datetime  :removed_at                    # soft delete
      t.timestamps
    end
    add_index :safe_owners, :safe_wallet_id
    add_index :safe_owners, [ :safe_wallet_id, :evm_address ], unique: true

    create_table :safe_transactions, id: :string do |t|
      t.string  :safe_wallet_id,    null: false
      t.string  :proposer_id,       null: false
      t.string  :to_address,        null: false
      t.decimal :value,             precision: 80, default: 0, null: false
      t.text    :data,              default: "0x"
      t.integer :operation,         default: 0, null: false   # 0=Call 1=DelegateCall
      t.decimal :safe_tx_gas,       precision: 40, default: 0
      t.decimal :base_gas,          precision: 40, default: 0
      t.decimal :gas_price,         precision: 40, default: 0
      t.string  :gas_token,         default: "0x0000000000000000000000000000000000000000"
      t.string  :refund_receiver,   default: "0x0000000000000000000000000000000000000000"
      t.integer :nonce,             null: false
      t.string  :safe_tx_hash,      null: false
      t.text    :description
      t.string  :status,            default: "pending", null: false  # pending|ready|executed|rejected|expired
      t.string  :on_chain_tx_hash
      t.datetime :executed_at
      t.datetime :expires_at
      t.timestamps
    end
    add_index :safe_transactions, :safe_wallet_id
    add_index :safe_transactions, :safe_tx_hash, unique: true
    add_index :safe_transactions, [ :safe_wallet_id, :status ]

    create_table :safe_signatures, id: :string do |t|
      t.string   :safe_transaction_id, null: false
      t.string   :signer_id                      # nil if not a Semi user
      t.string   :signer_address,      null: false
      t.string   :signature,           null: false
      t.datetime :signed_at,           null: false
      t.timestamps
    end
    add_index :safe_signatures, :safe_transaction_id
    add_index :safe_signatures, [ :safe_transaction_id, :signer_address ], unique: true
  end
end
