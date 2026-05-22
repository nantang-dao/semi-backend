class MigrateUserWallets < ActiveRecord::Migration[8.0]
  def up
    User.find_each do |user|
      next if user.evm_chain_address.blank?

      existing = Wallet.find_by(user_id: user.id, evm_chain_address: user.evm_chain_address)

      wallet = existing || Wallet.create!(
        id:                   Tsid::Generator.new.generate,
        user_id:              user.id,
        name:                 "Main Wallet",
        wallet_type:          "eoa",
        chain:                "ethereum",
        chain_id:             1,
        evm_chain_address:    user.evm_chain_address,
        evm_chain_active_key: user.evm_chain_active_key,
        encrypted_keys:       user.encrypted_keys,
        is_primary:           true
      )

      user.update_columns(active_wallet_id: wallet.id)
    end
  end

  def down
    User.find_each do |user|
      primary = Wallet.find_by(user_id: user.id, is_primary: true)
      next unless primary
      user.update_columns(active_wallet_id: nil)
      primary.destroy
    end
  end
end
