require "test_helper"

# 改动之前，一个 token 一旦签发就**永久有效**：表里的 disabled 列没有任何地方
# 检查（等于一个没接线的开关），也没有任何过期概念。抄走 token 的人可以一直用，
# 用户点多少次「退出」都不影响他。
class AuthTokenTest < ActiveSupport::TestCase
  setup { @user = User.create(phone: "13900000001") }

  test "签发时自动填上一年后的过期时间" do
    token = AuthToken.create(user: @user)
    assert token.expires_at.present?
    assert_in_delta 1.year.from_now.to_i, token.expires_at.to_i, 60
  end

  test "usable 认可正常的 token" do
    token = AuthToken.create(user: @user)
    assert token.usable?
    assert_includes AuthToken.usable, token
  end

  # 这条就是那个一直没接线的开关
  test "usable 排除已吊销的 token" do
    token = AuthToken.create(user: @user)
    token.revoke!

    assert_not token.usable?
    assert_not_includes AuthToken.usable, token
    assert token.persisted?, "吊销不删记录，排查时要能看到它什么时候失效的"
  end

  test "usable 排除已过期的 token" do
    token = AuthToken.create(user: @user)
    token.update_column(:expires_at, 1.minute.ago)

    assert_not token.reload.usable?
    assert_not_includes AuthToken.usable, token
  end

  test "last_used_at 首次访问即记录" do
    token = AuthToken.create(user: @user)
    assert_nil token.last_used_at

    token.touch_last_used!
    assert token.reload.last_used_at.present?
  end

  # 每个请求都写一次数据库不可接受，而这个字段不需要秒级精度
  test "last_used_at 一小时内不重复写" do
    token = AuthToken.create(user: @user)
    token.touch_last_used!
    first = token.reload.last_used_at

    token.touch_last_used!
    assert_equal first.to_i, token.reload.last_used_at.to_i
  end

  test "last_used_at 超过一小时后再写" do
    token = AuthToken.create(user: @user)
    token.update_column(:last_used_at, 2.hours.ago)

    token.touch_last_used!
    assert_operator token.reload.last_used_at, :>, 1.minute.ago
  end

  # updated_at 要留给「什么时候被吊销的」，不能被每小时一次的心跳冲掉
  test "写 last_used_at 不动 updated_at" do
    token = AuthToken.create(user: @user)
    before = token.updated_at

    token.touch_last_used!
    assert_equal before.to_i, token.reload.updated_at.to_i
  end

  test "签发新 token 时把该用户已过期的标记为已吊销" do
    stale = AuthToken.create(user: @user)
    stale.update_column(:expires_at, 1.day.ago)
    other_device = AuthToken.create(user: @user)

    @user.gen_auth_token

    assert stale.reload.disabled?, "过期的应被标记"
    assert_not other_device.reload.disabled?, "其他设备还活着的 token 不能动"
  end
  # 滚动部署时新旧容器会同时在跑：migration 由新容器启动时执行，而旧容器的
  # AuthToken 不知道 expires_at 的存在，插入时不带这一列。没有数据库默认值的话
  # NOT NULL 会让旧容器上的每一次登录直接 500，直到它被换掉。
  test "不带 expires_at 的插入由数据库默认值兜住" do
    conn = ActiveRecord::Base.connection
    conn.execute(
      "INSERT INTO auth_tokens (token, user_id, disabled, created_at, updated_at) " \
      "VALUES (#{conn.quote('legacy-insert')}, #{conn.quote(@user.id)}, false, now(), now())"
    )

    token = AuthToken.find_by(token: "legacy-insert")
    assert token.expires_at.present?, "数据库默认值没生效，滚动部署会打断登录"
    assert token.usable?
    assert_in_delta 1.year.from_now.to_i, token.expires_at.to_i, 120
  end
end
