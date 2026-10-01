# keystore v2：解密要服务端的 key_share，服务端核对支付码 verifier 后才下发，并限制失败次数。
# 见 docs/keystore.md。全部可空 / 有默认值，老用户（v1）不受影响，下次输支付码时由前端升级。
class AddKeystoreV2ToUsers < ActiveRecord::Migration[8.0]
  def change
    add_column :users, :keystore_verifier_mac, :string
    add_column :users, :key_share_ciphertext, :string
    add_column :users, :keystore_failed_attempts, :integer, default: 0, null: false
    add_column :users, :keystore_locked_until, :datetime
    add_column :users, :keystore_updated_at, :datetime
  end
end
