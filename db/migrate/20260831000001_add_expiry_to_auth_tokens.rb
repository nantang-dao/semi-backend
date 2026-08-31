class AddExpiryToAuthTokens < ActiveRecord::Migration[8.0]
  def up
    # 数据库级默认值不是给应用代码用的（AuthToken 会自己填），是为了**滚动部署**。
    #
    # 部署时新旧容器会同时在跑一小段时间。这个 migration 由新容器启动时的
    # db:prepare 执行，而此刻旧容器仍在服务 —— 它的 AuthToken 不知道
    # expires_at 的存在，插入时不带这一列。没有默认值的话，NOT NULL 会让
    # 旧容器上的每一次登录直接 500，直到它被换掉。
    add_column :auth_tokens, :expires_at, :datetime,
               default: -> { "now() + interval '1 year'" }
    add_column :auth_tokens, :last_used_at, :datetime

    # 已签发的 token 按「签发那天起一年」补齐，而不是「从现在起一年」——
    # 后者会把一批本该早就失效的旧 token 又续上一年。
    # 前端 cookie 本来就是 365 天，所以超过一年的 token 浏览器侧早已不可用，
    # 这次补齐不会把任何还在用的人踢下线。
    execute <<~SQL
      UPDATE auth_tokens SET expires_at = created_at + INTERVAL '1 year' WHERE expires_at IS NULL
    SQL

    change_column_null :auth_tokens, :expires_at, false

    # current_user 每个请求都按 (token, disabled, expires_at) 查一次
    add_index :auth_tokens, [ :token, :disabled, :expires_at ], name: "index_auth_tokens_on_lookup"
  end

  def down
    remove_index :auth_tokens, name: "index_auth_tokens_on_lookup"
    remove_column :auth_tokens, :last_used_at
    remove_column :auth_tokens, :expires_at
  end
end
