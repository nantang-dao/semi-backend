# This file is auto-generated from the current state of the database. Instead
# of editing this file, please use the migrations feature of Active Record to
# incrementally modify your database, and then regenerate this schema definition.
#
# This file is the source Rails uses to define your schema when running `bin/rails
# db:schema:load`. When creating a new database, `bin/rails db:schema:load` tends to
# be faster and is potentially less error prone than running all of your
# migrations from scratch. Old migrations may fail to apply correctly if those
# migrations use external dependencies or application code.
#
# It's strongly recommended that you check this file into your version control system.

ActiveRecord::Schema[8.0].define(version: 2026_07_04_000001) do
  create_schema "auth"
  create_schema "extensions"
  create_schema "graphql"
  create_schema "graphql_public"
  create_schema "pgbouncer"
  create_schema "realtime"
  create_schema "storage"
  create_schema "vault"
  # These are extensions that must be enabled in order to support this database
  enable_extension "extensions.pg_stat_statements"
  enable_extension "extensions.pgcrypto"
  enable_extension "extensions.uuid-ossp"
  enable_extension "pg_catalog.plpgsql"
  enable_extension "vault.supabase_vault"

  create_table "auth_tokens", force: :cascade do |t|
    t.string "token", null: false
    t.string "user_id", null: false
    t.boolean "disabled", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["token"], name: "index_auth_tokens_on_token", unique: true
    t.index ["user_id"], name: "index_auth_tokens_on_user_id"
  end

  create_table "multisig_signatures", id: false, force: :cascade do |t|
    t.string "multisig_transaction_id", null: false
    t.string "signer_address", null: false
    t.text "signature", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["multisig_transaction_id", "signer_address"], name: "idx_multisig_sigs_unique", unique: true
    t.index ["multisig_transaction_id"], name: "index_multisig_signatures_on_multisig_transaction_id"
  end

  create_table "multisig_transactions", id: :string, force: :cascade do |t|
    t.string "wallet_id", null: false
    t.string "proposer_id", null: false
    t.integer "chain_id", null: false
    t.integer "queue_position"
    t.string "nonce"
    t.string "tx_type", null: false
    t.jsonb "call_detail", default: {}, null: false
    t.text "evm_call_data", default: "", null: false
    t.jsonb "user_op_snapshot"
    t.integer "threshold_at_creation", null: false
    t.string "replaces_tx_id"
    t.string "status", default: "queued", null: false
    t.string "tx_hash"
    t.datetime "expires_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.jsonb "owner_snapshot"
    t.string "memo"
    t.string "sender_note"
    t.string "executor_id"
    t.decimal "gas_used", precision: 80, default: "0", null: false
    t.index ["executor_id"], name: "index_multisig_transactions_on_executor_id"
    t.index ["wallet_id", "queue_position"], name: "index_multisig_transactions_on_wallet_id_and_queue_position"
    t.index ["wallet_id", "status"], name: "index_multisig_transactions_on_wallet_id_and_status"
    t.index ["wallet_id"], name: "index_multisig_transactions_on_wallet_id"
  create_table "handle_aliases", force: :cascade do |t|
    t.string "user_id", null: false
    t.string "alias", null: false
    t.datetime "expires_at", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["alias"], name: "index_handle_aliases_on_alias", unique: true
    t.index ["user_id"], name: "index_handle_aliases_on_user_id"
  end

  create_table "oauth_access_tokens", force: :cascade do |t|
    t.string "token", null: false
    t.string "user_id", null: false
    t.bigint "application_id", null: false
    t.jsonb "scopes", default: [], null: false
    t.datetime "expires_at", null: false
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["application_id"], name: "index_oauth_access_tokens_on_application_id"
    t.index ["token"], name: "index_oauth_access_tokens_on_token", unique: true
    t.index ["user_id"], name: "index_oauth_access_tokens_on_user_id"
  end

  create_table "oauth_applications", force: :cascade do |t|
    t.string "client_id", null: false
    t.string "client_secret_digest", null: false
    t.string "name", null: false
    t.jsonb "redirect_uris", default: [], null: false
    t.jsonb "allowed_scopes", default: [], null: false
    t.string "status", default: "draft", null: false
    t.string "owner_id", null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["client_id"], name: "index_oauth_applications_on_client_id", unique: true
    t.index ["owner_id"], name: "index_oauth_applications_on_owner_id"
  end

  create_table "oauth_authorization_codes", force: :cascade do |t|
    t.string "code", null: false
    t.string "user_id", null: false
    t.bigint "application_id", null: false
    t.jsonb "scopes", default: [], null: false
    t.string "redirect_uri", null: false
    t.string "code_challenge", null: false
    t.string "code_challenge_method", default: "S256", null: false
    t.datetime "expires_at", null: false
    t.boolean "used", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["application_id"], name: "index_oauth_authorization_codes_on_application_id"
    t.index ["code"], name: "index_oauth_authorization_codes_on_code", unique: true
    t.index ["user_id"], name: "index_oauth_authorization_codes_on_user_id"
  end

  create_table "oauth_grants", force: :cascade do |t|
    t.string "user_id", null: false
    t.bigint "application_id", null: false
    t.jsonb "scopes", default: [], null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["user_id", "application_id"], name: "index_oauth_grants_on_user_id_and_application_id", unique: true
    t.index ["user_id"], name: "index_oauth_grants_on_user_id"
  end

  create_table "oauth_refresh_tokens", force: :cascade do |t|
    t.string "token", null: false
    t.string "user_id", null: false
    t.bigint "application_id", null: false
    t.bigint "access_token_id", null: false
    t.datetime "expires_at", null: false
    t.datetime "revoked_at"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["access_token_id"], name: "index_oauth_refresh_tokens_on_access_token_id"
    t.index ["token"], name: "index_oauth_refresh_tokens_on_token", unique: true
    t.index ["user_id"], name: "index_oauth_refresh_tokens_on_user_id"
  end

  create_table "token_classes", force: :cascade do |t|
    t.string "token_type", null: false, comment: "ERC20, ERC721, ERC1155"
    t.string "chain", null: false, comment: "ethereum, optimism, solana, etc"
    t.string "address", null: false, comment: "token address"
    t.string "name"
    t.string "symbol"
    t.string "image_url"
    t.string "publisher"
    t.string "publisher_address"
    t.integer "position", default: 0
    t.text "description"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "decimals", default: 18
    t.integer "chain_id", default: 0
  end

  create_table "transactions", force: :cascade do |t|
    t.string "user_id"
    t.string "chain"
    t.text "data"
    t.string "status"
    t.string "tx_hash"
    t.decimal "gas_used", precision: 80
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "wallet_id"
    t.string "memo"
    t.string "sender_note"
    t.string "receiver_note"
    t.string "receiver_address"
    t.string "sender_address"
    t.string "metadata"
    t.jsonb "extra", default: {}
  end

  create_table "users", id: :string, force: :cascade do |t|
    t.string "handle"
    t.string "email"
    t.string "phone"
    t.string "image_url"
    t.jsonb "encrypted_keys"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.string "evm_chain_address"
    t.string "evm_chain_active_key"
    t.integer "remaining_gas_credits", default: 0, null: false
    t.decimal "total_used_gas_credits", precision: 80, default: "0", null: false
    t.string "encrypted_password"
    t.boolean "phone_verified", default: false
    t.integer "transaction_count", default: 0, null: false
    t.boolean "can_send_badge", default: false
    t.jsonb "contact_list"
    t.datetime "handle_changed_at"
    t.index ["email"], name: "index_users_on_email", unique: true
    t.index ["handle"], name: "index_users_on_handle", unique: true
    t.index ["phone"], name: "index_users_on_phone", unique: true
  end

  create_table "verification_tokens", force: :cascade do |t|
    t.string "context", null: false
    t.string "sent_to", null: false
    t.string "code", null: false
    t.datetime "expires_at", null: false
    t.boolean "used", default: false, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
  end

  create_table "wallet_owners", id: :string, force: :cascade do |t|
    t.string "wallet_id", null: false
    t.string "user_id"
    t.string "owner_address", null: false
    t.integer "position", default: 0, null: false
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.index ["wallet_id", "owner_address"], name: "index_wallet_owners_on_wallet_id_and_owner_address", unique: true
    t.index ["wallet_id"], name: "index_wallet_owners_on_wallet_id"
  end

  create_table "wallets", id: :string, force: :cascade do |t|
    t.string "user_id"
    t.string "name"
    t.string "wallet_type"
    t.string "chain"
    t.string "evm_chain_address"
    t.string "evm_chain_active_key"
    t.jsonb "encrypted_keys"
    t.string "format"
    t.datetime "created_at", null: false
    t.datetime "updated_at", null: false
    t.integer "threshold", default: 1, null: false
    t.integer "chain_id"
  end

  add_foreign_key "auth_tokens", "users"
  add_foreign_key "handle_aliases", "users"
  add_foreign_key "oauth_access_tokens", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_access_tokens", "users"
  add_foreign_key "oauth_applications", "users", column: "owner_id"
  add_foreign_key "oauth_authorization_codes", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_authorization_codes", "users"
  add_foreign_key "oauth_grants", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_grants", "users"
  add_foreign_key "oauth_refresh_tokens", "oauth_access_tokens", column: "access_token_id"
  add_foreign_key "oauth_refresh_tokens", "oauth_applications", column: "application_id"
  add_foreign_key "oauth_refresh_tokens", "users"
end
