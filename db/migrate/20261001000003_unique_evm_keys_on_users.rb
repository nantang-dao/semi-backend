# 一把签名私钥、一个 Safe 地址只能属于一个账户。按 LOWER 建：历史数据大小写混用。
#
# 生产上原有 2 组重复（同一个人把同一把私钥导入多个账户），2026-10-01 已按 docs/auth.md
# 的记录合并 / 解绑。旧代码在上线前仍可能写进新的重复，部署前先跑 docs/auth.md 里的
# 查重查询——这里失败会让新容器起不来。
class UniqueEvmKeysOnUsers < ActiveRecord::Migration[8.0]
  def change
    add_index :users, "LOWER(evm_chain_active_key)", unique: true,
              name: "index_users_on_lower_evm_chain_active_key", where: "evm_chain_active_key IS NOT NULL"
    add_index :users, "LOWER(evm_chain_address)", unique: true,
              name: "index_users_on_lower_evm_chain_address", where: "evm_chain_address IS NOT NULL"
  end
end
