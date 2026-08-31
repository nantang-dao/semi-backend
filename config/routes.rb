Rails.application.routes.draw do
  # Define your application routes per the DSL in https://guides.rubyonrails.org/routing.html

  # Reveal health status on /up that returns 200 if the app boots with no exceptions, otherwise 500.
  # Can be used by load balancers and uptime monitors to verify that the app is live.
  get "up" => "rails/health#show", as: :rails_health_check

  root "home#index"
  post "send_sms" => "home#send_sms"
  post "send_email" => "home#send_email"
  post "signin" => "home#signin"
  post "signin_with_email" => "home#signin_with_email"
  post "signin_with_password" => "home#signin_with_password"
  post "set_handle" => "home#set_handle"
  post "set_image_url" => "home#set_image_url"
  post "upload_image" => "home#upload_image"
  get  "get_by_handle" => "home#get_by_handle"
  get  "get_user" => "home#get_user"
  get  "get_me" => "home#get_me"
  post "logout" => "home#logout"
  post "logout_all" => "home#logout_all"
  get  "remaining_free_transactions" => "home#remaining_free_transactions"
  get  "get_encrypted_keys" => "home#get_encrypted_keys"
  post "set_encrypted_keys" => "home#set_encrypted_keys"
  post "set_evm_chain_address" => "home#set_evm_chain_address"
  get  "get_transactions" => "home#get_transactions"
  post "add_transaction" => "home#add_transaction"
  post "add_transaction_with_gas_credits" => "home#add_transaction_with_gas_credits"
  post "set_transaction_note" => "home#set_transaction_note"
  get  "get_token_classes" => "home#get_token_classes"
  post "add_token_class" => "home#add_token_class"
  post "add_wallet" => "home#add_wallet"
  get  "get_wallets" => "home#get_wallets"
  post "remove_wallet" => "home#remove_wallet"
  post "set_contacts" => "home#set_contacts"
  get  "get_contacts" => "home#get_contacts"

  # Multisig
  post "create_multisig_wallet"       => "multisig#create_wallet"
  get  "get_multisig_wallets"         => "multisig#get_wallets"
  get  "get_multisig_wallet_owners"   => "multisig#get_wallet_owners"
  post "sync_multisig_wallet"         => "multisig#sync_wallet"
  post "propose_multisig_tx"          => "multisig#propose_tx"
  get  "get_multisig_txs"             => "multisig#get_txs"
  get  "get_multisig_tx"              => "multisig#get_tx"
  post "submit_multisig_signature"    => "multisig#submit_signature"
  post "execute_multisig_tx"          => "multisig#execute_tx"
  post "confirm_multisig_tx"          => "multisig#confirm_tx"
  post "fail_multisig_tx"             => "multisig#fail_tx"
  post "reset_executing_multisig_tx"  => "multisig#reset_executing_tx"
  post "withdraw_multisig_tx"         => "multisig#withdraw_tx"
  get  "lookup_multisig_tx_memos"    => "multisig#lookup_tx_memos"

  # Badges —— 调用方只有 semi-app 的 Nitro 层，用 X-Service-Token 认证。
  # 链上写入留在 Nitro（后端不签名），这里只有数据。
  scope "/badge" do
    get  "profile"         => "badges#show_profile"
    post "profile"         => "badges#create_profile"
    get  "classes"         => "badges#list_classes"
    get  "classes/details" => "badges#class_details"
    post "classes"         => "badges#create_class"
    get  "owned"           => "badges#owned"
    get  "pending"         => "badges#pending"
    get  "summary"         => "badges#summary"
    get  "item"            => "badges#show_badge"
    post "items"           => "badges#create_badges"
    post "accept"          => "badges#accept"
    post "reject"          => "badges#reject"
  end

  # OIDC Discovery
  get ".well-known/openid-configuration" => "oauth#openid_configuration"

  # OAuth 2.0 core endpoints
  scope "/oauth" do
    get    "authorize"        => "oauth#authorize_info"
    post   "authorize"        => "oauth#authorize_decision"
    post   "token"            => "oauth#token"
    get    "userinfo"         => "oauth#userinfo"
    post   "revoke"           => "oauth#revoke"
    get    "jwks"             => "oauth#jwks"

    # Developer portal
    get    "applications"     => "oauth#list_applications"
    post   "applications"     => "oauth#create_application"
    patch  "applications/:id" => "oauth#update_application"
    delete "applications/:id" => "oauth#destroy_application"

    # Admin endpoints
    get    "admin/applications" => "oauth#admin_list_applications"

    # User grants management
    get    "grants"           => "oauth#list_grants"
    delete "grants/:id"       => "oauth#destroy_grant"
  end

  # Defines the root path route ("/")
end
