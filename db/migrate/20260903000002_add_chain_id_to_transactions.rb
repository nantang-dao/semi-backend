# 多链支持：单签 transactions 表加 chain_id 整数列
#
# transactions.chain 字段存的是链名字符串（如 "optimism"、"ethereum"、"sepolia"），
# 由前端 transfer.client.vue 写入 useChain.chain.name.toLowerCase()。
# 字符串匹配不可靠且无法精确按链过滤，加一个整数 chain_id 列并回填。
#
# 回填规则基于实际代码验证：chain 字段为以下值之一：
#   "optimism"  -> 10
#   "ethereum"  -> 1
#   "sepolia"   -> 11155111
# 无法匹配的行设为 0
class AddChainIdToTransactions < ActiveRecord::Migration[8.0]
  def up
    add_column :transactions, :chain_id, :integer

    # 回填：从 chain 字符串推断 chain_id
    execute <<~SQL
      UPDATE transactions SET chain_id = 10
        WHERE chain IN ('optimism', '10') AND chain_id IS NULL;
      UPDATE transactions SET chain_id = 1
        WHERE chain IN ('ethereum', 'mainnet', '1') AND chain_id IS NULL;
      UPDATE transactions SET chain_id = 11155111
        WHERE chain IN ('sepolia', '11155111') AND chain_id IS NULL;
      -- 无法匹配的行设为 0，需人工排查
      UPDATE transactions SET chain_id = 0
        WHERE chain_id IS NULL;
    SQL

    change_column_null :transactions, :chain_id, false
    add_index :transactions, [:user_id, :chain_id], name: "index_transactions_on_user_and_chain"
  end

  def down
    remove_index :transactions, name: "index_transactions_on_user_and_chain"
    remove_column :transactions, :chain_id
  end
end
