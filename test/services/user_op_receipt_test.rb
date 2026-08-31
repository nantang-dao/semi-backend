require "test_helper"

# 打包交易成功 ≠ 这笔 UserOperation 成功。EntryPoint 会 catch 住内层调用的
# revert，handleOps 照样返回 status 0x1 —— 成败只写在 UserOperationEvent 里。
class UserOpReceiptTest < ActiveSupport::TestCase
  SAFE = "0x#{'0' * 24}7a3ed6502f876e4e940eb34fb33309e8551c5070".freeze
  OTHER = "0x#{'0' * 24}1111111111111111111111111111111111111111".freeze
  OP_HASH = "0x#{'ab' * 32}".freeze

  def word(n) = n.to_s(16).rjust(64, "0")

  def event(sender:, success:, op_hash: OP_HASH)
    {
      "topics" => [ UserOpReceipt::EVENT_TOPIC, op_hash, sender, "0x#{'0' * 64}" ],
      "data" => "0x#{word(5)}#{word(success ? 1 : 0)}#{word(1234)}#{word(99)}"
    }
  end

  test "成功的 UserOp 放行" do
    assert_nothing_raised do
      UserOpReceipt.assert_succeeded!([ event(sender: SAFE, success: true) ], SAFE)
    end
  end

  # 这一条就是那个洞：不查 success 位，这笔会被标记成 executed
  test "内层回滚的 UserOp 被拒绝" do
    err = assert_raises(UserOpReceipt::Reverted) do
      UserOpReceipt.assert_succeeded!([ event(sender: SAFE, success: false) ], SAFE)
    end
    assert_match(/内层调用回滚/, err.message)
  end

  test "别的 Safe 的成功事件不算数" do
    assert_raises(UserOpReceipt::NotFound) do
      UserOpReceipt.assert_succeeded!([ event(sender: OTHER, success: true) ], SAFE)
    end
  end

  test "同一 bundle 里别人成功、自己失败时拒绝" do
    logs = [ event(sender: OTHER, success: true), event(sender: SAFE, success: false) ]
    assert_raises(UserOpReceipt::Reverted) { UserOpReceipt.assert_succeeded!(logs, SAFE) }
  end

  test "给了 user_op_hash 时只看自己那一笔" do
    mine = event(sender: SAFE, success: true, op_hash: "0x#{'cd' * 32}")
    theirs = event(sender: SAFE, success: false, op_hash: "0x#{'ef' * 32}")
    assert_nothing_raised do
      UserOpReceipt.assert_succeeded!([ theirs, mine ], SAFE, "0x#{'cd' * 32}")
    end
    assert_raises(UserOpReceipt::Reverted) do
      UserOpReceipt.assert_succeeded!([ theirs, mine ], SAFE, "0x#{'ef' * 32}")
    end
  end

  test "user_op_hash 在回执里找不到时拒绝" do
    assert_raises(UserOpReceipt::NotFound) do
      UserOpReceipt.assert_succeeded!([ event(sender: SAFE, success: true) ], SAFE, "0x#{'99' * 32}")
    end
  end

  # 失败闭合：看不懂的回执不该被判成成功
  test "没有 UserOperationEvent 时拒绝" do
    assert_raises(UserOpReceipt::NotFound) do
      UserOpReceipt.assert_succeeded!([ { "topics" => [ "0xdead" ], "data" => "0x" } ], SAFE)
    end
  end

  test "data 太短读不出 success 时当作失败" do
    short = { "topics" => [ UserOpReceipt::EVENT_TOPIC, OP_HASH, SAFE, "0x0" ], "data" => "0x#{word(5)}" }
    assert_raises(UserOpReceipt::Reverted) { UserOpReceipt.assert_succeeded!([ short ], SAFE) }
  end
end
