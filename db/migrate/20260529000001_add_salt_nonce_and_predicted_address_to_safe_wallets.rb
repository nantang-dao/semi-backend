class AddSaltNonceAndPredictedAddressToSafeWallets < ActiveRecord::Migration[8.0]
  def change
    # salt_nonce: the CREATE2 saltNonce used to derive the Safe address.
    #   Stored at creation (default random, user-overridable) so the address is
    #   deterministic and reproducible across deploy/retry/chains.
    # predicted_address: the deterministic Safe address computed at creation.
    #   safe_address is still only set after the on-chain deploy succeeds.
    add_column :safe_wallets, :salt_nonce, :string
    add_column :safe_wallets, :predicted_address, :string
    add_index  :safe_wallets, :predicted_address
  end
end
