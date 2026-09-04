# 多链支持：多签钱包按 (evm_chain_address, chain_id) 唯一
#
# Safe 地址由 CREATE2 算出，同一组 owners+threshold 在所有链上相同，
# 但每条链上是独立的合约实例。后端必须把每条 (safe_address, chain_id)
# 当作独立逻辑钱包处理，允许同一地址在不同链上各建一条记录。
class AddUniqueIndexOnWalletAddressAndChain < ActiveRecord::Migration[8.0]
  def up
    add_index :wallets, [:evm_chain_address, :chain_id],
              unique: true,
              name: "index_wallets_on_address_and_chain"
  end

  def down
    remove_index :wallets, name: "index_wallets_on_address_and_chain"
  end
end
