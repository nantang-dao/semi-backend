class MultisigMultichain < ActiveRecord::Migration[8.0]
  # 多签按链拆分：同一个 Safe 地址在每条链上是一行 wallet。
  #
  # - initial_owners / initial_threshold：Safe 部署时（CREATE2 预测地址时）用的
  #   配置。在一条还没部署的链上，Safe 的有效 owner 就是这份初始配置——
  #   第一笔 UserOp 用它生成 initCode。新增链的 wallet 行按它建。
  # - multisig_transactions.group_id：一次 owner 变更在各条链上各一笔交易，
  #   用它关联。
  def up
    add_column :wallets, :initial_owners, :jsonb
    add_column :wallets, :initial_threshold, :integer
    add_column :multisig_transactions, :group_id, :string
    add_index :multisig_transactions, :group_id

    # 老行只写了 chain 字符串，没有 chain_id；按链查同地址的其他行要靠 chain_id
    execute(<<~SQL)
      UPDATE wallets SET chain_id = chain::integer
      WHERE wallet_type = 'multisig' AND chain_id IS NULL AND chain ~ '^[0-9]+$'
    SQL

    backfill_initial_config

    # 同一个地址同一条链只能有一行。按 LOWER 建索引，不改老数据的地址大小写。
    add_index :wallets, "LOWER(evm_chain_address), chain_id",
              unique: true,
              where: "wallet_type = 'multisig'",
              name: "index_multisig_wallets_on_address_and_chain"
  end

  def down
    remove_index :wallets, name: "index_multisig_wallets_on_address_and_chain"
    remove_index :multisig_transactions, :group_id
    remove_column :multisig_transactions, :group_id
    remove_column :wallets, :initial_threshold
    remove_column :wallets, :initial_owners
  end

  private

  CONFIG_TYPES = %w[add_owner remove_owner change_threshold replace_owner].freeze

  # 老钱包没有记录初始配置，按以下顺序还原：
  # 1. 最早一笔已执行的配置交易：owner_snapshot 冻结于执行前（= 变更前的 owner），
  #    threshold_at_creation 是提案时的门限，在它之前没有配置变更执行过，所以就是初始值。
  # 2. 从没执行过配置交易：当前 owner / 门限就是初始值。
  #
  # 在 Semi 之外改过 owner 的钱包会还原错。前端在给新链建行前会用这份配置
  # 预测地址，与 Safe 地址对不上就不建，所以错的配置不会被用上。
  def backfill_initial_config
    select_rows("SELECT id, threshold FROM wallets WHERE wallet_type = 'multisig'").each do |wallet_id, threshold|
      first_config = select_one(<<~SQL)
        SELECT owner_snapshot, threshold_at_creation FROM multisig_transactions
        WHERE wallet_id = #{quote(wallet_id)} AND status = 'executed'
          AND tx_type IN (#{CONFIG_TYPES.map { |t| quote(t) }.join(",")})
        ORDER BY updated_at ASC LIMIT 1
      SQL

      owners, init_threshold =
        if first_config
          snapshot = first_config["owner_snapshot"]
          snapshot = JSON.parse(snapshot) if snapshot.is_a?(String)
          list = snapshot.is_a?(Hash) ? snapshot["owners"] : snapshot
          [ Array(list).map { |o| o["address"].to_s.downcase }, first_config["threshold_at_creation"] ]
        else
          [ select_values("SELECT LOWER(owner_address) FROM wallet_owners WHERE wallet_id = #{quote(wallet_id)}"), threshold ]
        end

      next if owners.empty?

      execute(<<~SQL)
        UPDATE wallets SET initial_owners = #{quote(owners.sort.to_json)}::jsonb,
                           initial_threshold = #{init_threshold.to_i}
        WHERE id = #{quote(wallet_id)}
      SQL
    end
  end
end
