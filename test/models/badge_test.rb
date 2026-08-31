require "test_helper"

class BadgeTest < ActiveSupport::TestCase
  # 迁移用的 checksummed 地址，故意大小写混合 —— 它参与 namehash，不能被 normalize。
  ADDRESS = "0xAbC0000000000000000000000000000000000123".freeze

  def new_badge(**overrides)
    Badge.new({
      badge_id: "0x#{SecureRandom.hex(32)}",
      class_id: "0x#{SecureRandom.hex(32)}",
      wallet_address: ADDRESS,
      chain_id: 10,
      status: "pending",
      metadata: { badge_name: "n" }
    }.merge(overrides))
  end

  test "主键用 TSID，13 位 base32" do
    badge = new_badge
    badge.save!
    assert_equal 13, badge.id.length
  end

  test "wallet_address 原样保存，不被改成小写" do
    badge = new_badge
    badge.save!
    assert_equal ADDRESS, badge.reload.wallet_address
  end

  test "generated 列让查询大小写不敏感" do
    new_badge.save!
    assert_equal 1, Badge.for_wallet(ADDRESS.downcase, 10).count
    assert_equal 1, Badge.for_wallet(ADDRESS.upcase.sub("0X", "0x"), 10).count
    assert_equal 0, Badge.for_wallet(ADDRESS, 1).count
  end

  test "非法 status 被数据库挡住，不只是模型校验" do
    badge = new_badge
    badge.save!
    assert_raises(ActiveRecord::StatementInvalid) do
      Badge.connection.execute(
        "UPDATE badges SET status = 'bogus' WHERE id = #{Badge.connection.quote(badge.id)}"
      )
    end
  end

  test "badge_id 唯一" do
    first = new_badge
    first.save!
    duplicate = new_badge(badge_id: first.badge_id)
    assert_not duplicate.valid?
  end

  test "instant_id 唯一但允许多行为空" do
    new_badge(instant_id: nil).save!
    new_badge(instant_id: nil).save!
    new_badge(instant_id: "abc").save!
    assert_raises(ActiveRecord::RecordNotUnique) do
      Badge.connection.execute(
        "INSERT INTO badges (id, badge_id, class_id, wallet_address, chain_id, status, metadata, instant_id, created_at, updated_at) " \
        "VALUES ('x', '0x01', '0x02', '#{ADDRESS}', 10, 'pending', '{}', 'abc', now(), now())"
      )
    end
  end

  test "class_id 关联到 BadgeClass" do
    klass = BadgeClass.create!(
      class_id: "0x#{SecureRandom.hex(32)}",
      chain_id: 10,
      profile_id: "0x#{SecureRandom.hex(32)}",
      wallet_address: ADDRESS,
      badge_contract_address: "0x0000000000000000000000000000000000000001",
      metadata: {}
    )
    badge = new_badge(class_id: klass.class_id)
    badge.save!
    assert_equal klass, badge.reload.badge_class
    assert_equal [ badge ], klass.reload.badges.to_a
  end
end
