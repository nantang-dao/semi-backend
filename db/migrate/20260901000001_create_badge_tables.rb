class CreateBadgeTables < ActiveRecord::Migration[8.0]
  def change
    # 徽章数据从 InstantDB 迁过来。三张表原本是 Instant 的 profiles /
    # badge_classes / badges，schema 是平的（links 全空），关联靠字符串字段手接。
    #
    # 两个不能动的约束：
    #   1. profile_id / class_id / badge_id 是 namehash 出来的 32 字节 hex，
    #      前端 BigInt(...) 之后直接进合约 args —— 已经写在链上了，必须逐字保留。
    #   2. wallet_address 参与上面那个 namehash 的输入，大小写变了 id 就变了。
    #      所以原样存 checksummed 地址，另开一个 generated 列供大小写不敏感查询。

    create_table :badge_profiles, id: :string do |t|
      t.string :profile_id, null: false          # namehash("<addr>.<chain>.semi")
      t.string :wallet_address, null: false      # checksummed，不可 normalize
      t.integer :chain_id, null: false
      t.string :tx_hash
      t.string :instant_id                       # 迁移来源行，用于核对与重跑幂等

      t.virtual :wallet_address_lower, type: :string, as: "lower(wallet_address)", stored: true

      t.timestamps
    end

    add_index :badge_profiles, :profile_id, unique: true
    add_index :badge_profiles, [ :wallet_address_lower, :chain_id ]
    add_index :badge_profiles, :instant_id, unique: true, where: "instant_id IS NOT NULL"

    create_table :badge_classes, id: :string do |t|
      t.string :class_id, null: false            # namehash("<uuid>.<addr>.<chain>.semi")
      t.integer :chain_id, null: false
      t.string :profile_id, null: false
      t.string :wallet_address, null: false
      t.string :badge_contract_address, null: false
      t.jsonb :metadata, null: false, default: {}
      t.string :tx_hash
      t.string :instant_id

      t.virtual :wallet_address_lower, type: :string, as: "lower(wallet_address)", stored: true

      t.timestamps
    end

    add_index :badge_classes, :class_id, unique: true
    add_index :badge_classes, [ :profile_id, :chain_id ]
    add_index :badge_classes, [ :wallet_address_lower, :chain_id ]
    add_index :badge_classes, :instant_id, unique: true, where: "instant_id IS NOT NULL"

    create_table :badges, id: :string do |t|
      t.string :badge_id, null: false            # namehash("<uuid>.<class>.<addr>.<chain>.semi")
      t.string :class_id, null: false
      t.string :wallet_address, null: false      # 收件人，未必是 Semi 用户，故不设外键
      t.jsonb :metadata, null: false, default: {}
      t.integer :chain_id, null: false
      t.string :tx_hash                          # accepted 之前为空
      t.string :status, null: false, default: "pending"
      t.string :instant_id

      t.virtual :wallet_address_lower, type: :string, as: "lower(wallet_address)", stored: true

      # created_at 直接承接 Instant 的 badges.created_at，不另开列
      t.timestamps
    end

    add_index :badges, :badge_id, unique: true
    add_index :badges, [ :wallet_address_lower, :chain_id, :status ]
    add_index :badges, [ :class_id, :chain_id ]
    add_index :badges, :instant_id, unique: true, where: "instant_id IS NOT NULL"

    add_check_constraint :badges,
      "status IN ('pending', 'accepted', 'rejected')",
      name: "badges_status_check"
  end
end
