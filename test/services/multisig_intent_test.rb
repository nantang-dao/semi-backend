require "test_helper"

ApplicationController # AppError 定义在这个文件里，服务单独测试时要先加载它

# 编码向量由 semi-core 生成（encodeSafeCallData / encodeAddOwner …，见
# semi-app/packages/semi-core/test/snapshot-intent.test.ts）。前端签名前核对和后端
# 收快照时核对用的是两份实现，必须逐字节相同，否则正常提案会被一方拒掉。
class MultisigIntentTest < ActiveSupport::TestCase
  SAFE = "0x7a3Ed6502F876E4E940Eb34fb33309e8551C5070"
  BOB = "0x00000000000000000000000000000000000000b0"
  CAROL = "0x00000000000000000000000000000000000000c0"
  EVIL = "0x000000000000000000000000000000000000dead"
  USDC = "0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85"

  VECTORS = {
    eth: "0x541d63c800000000000000000000000000000000000000000000000000000000000000b0000000000000000000000000000000000000000000000000002386f26fc10000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
    erc20_data: "0xa9059cbb00000000000000000000000000000000000000000000000000000000000000b0000000000000000000000000000000000000000000000000000000000012d687",
    erc20: "0x541d63c80000000000000000000000000b2c639c533813f4aa9d7837caf62653d097ff850000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000044a9059cbb00000000000000000000000000000000000000000000000000000000000000b0000000000000000000000000000000000000000000000000000000000012d68700000000000000000000000000000000000000000000000000000000",
    add_owner_data: "0x0d582f1300000000000000000000000000000000000000000000000000000000000000b00000000000000000000000000000000000000000000000000000000000000002",
    add_owner: "0x541d63c80000000000000000000000007a3ed6502f876e4e940eb34fb33309e8551c507000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000440d582f1300000000000000000000000000000000000000000000000000000000000000b0000000000000000000000000000000000000000000000000000000000000000200000000000000000000000000000000000000000000000000000000",
    remove_owner_data: "0xf8dc5dd900000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000b00000000000000000000000000000000000000000000000000000000000000001",
    swap_owner_data: "0xe318b52b00000000000000000000000000000000000000000000000000000000000000c000000000000000000000000000000000000000000000000000000000000000b00000000000000000000000007a3ed6502f876e4e940eb34fb33309e8551c5070",
    change_threshold_data: "0x694e80c30000000000000000000000000000000000000000000000000000000000000003",
    cancel: "0x541d63c80000000000000000000000007a3ed6502f876e4e940eb34fb33309e8551c50700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000008000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000"
  }.freeze

  def hex(key) = VECTORS.fetch(key).delete_prefix("0x")

  test "Safe callData 与 semi-core 一致" do
    assert_equal hex(:eth), MultisigIntent.encode_safe_call_data(BOB, 10**16, "")
    assert_equal hex(:erc20), MultisigIntent.encode_safe_call_data(USDC, 0, hex(:erc20_data))
    assert_equal hex(:add_owner), MultisigIntent.encode_safe_call_data(SAFE, 0, hex(:add_owner_data))
    assert_equal hex(:cancel), MultisigIntent.encode_safe_call_data(SAFE, 0, "")
  end

  test "owner 变更 calldata 与 semi-core 一致" do
    assert_equal hex(:add_owner_data), MultisigIntent.config_call_data("add_owner", { new_owner: BOB, new_threshold: 2 }.with_indifferent_access)
    assert_equal hex(:remove_owner_data), MultisigIntent.config_call_data("remove_owner", { prev_owner: CAROL, owner: BOB, new_threshold: 1 }.with_indifferent_access)
    assert_equal hex(:swap_owner_data), MultisigIntent.config_call_data("replace_owner", { prev_owner: CAROL, old_owner: BOB, new_owner: SAFE }.with_indifferent_access)
    assert_equal hex(:change_threshold_data), MultisigIntent.config_call_data("change_threshold", { new_threshold: 3 }.with_indifferent_access)
  end

  # ── 提案 ──

  test "合法提案通过" do
    MultisigIntent.validate_proposal!("transfer", { to: BOB, amount: "0.01" }, "0x")
    MultisigIntent.validate_proposal!("erc20_transfer", { to: BOB, amount: "1.234567", decimals: 6, token_address: USDC }, VECTORS[:erc20_data])
    MultisigIntent.validate_proposal!("erc20_transfer", { to: BOB, amount: "1.234567", token_address: USDC }, VECTORS[:erc20_data])
    MultisigIntent.validate_proposal!("add_owner", { new_owner: BOB, new_threshold: 2 }, VECTORS[:add_owner_data])
    MultisigIntent.validate_proposal!("cancel", { replaces_tx_id: "x" }, "0x")
  end

  def assert_rejected(&block)
    err = assert_raises(AppError, &block)
    assert_equal "intent_mismatch", err.code, err.message
  end

  test "配置类交易的参数必须与展示内容一致，不只是选择器" do
    # 展示「加 Bob、门限 2」，calldata 却是「加 Evil、门限 1」
    forged = "0x" + MultisigIntent.config_call_data("add_owner", { new_owner: EVIL, new_threshold: 1 }.with_indifferent_access)
    assert_rejected { MultisigIntent.validate_proposal!("add_owner", { new_owner: BOB, new_threshold: 2 }, forged) }
  end

  test "ERC20 收款人或金额与展示不符被拒" do
    assert_rejected { MultisigIntent.validate_proposal!("erc20_transfer", { to: EVIL, amount: "1.234567", token_address: USDC }, VECTORS[:erc20_data]) }
    assert_rejected { MultisigIntent.validate_proposal!("erc20_transfer", { to: BOB, amount: "0.01", decimals: 6, token_address: USDC }, VECTORS[:erc20_data]) }
  end

  test "ETH 转账 / 拒签不能携带 calldata" do
    assert_rejected { MultisigIntent.validate_proposal!("transfer", { to: BOB, amount: "0.01" }, VECTORS[:erc20_data]) }
    assert_rejected { MultisigIntent.validate_proposal!("cancel", {}, VECTORS[:add_owner_data]) }
  end

  test "附加的 remark 调用被拒" do
    assert_rejected do
      MultisigIntent.validate_proposal!("transfer", { to: BOB, amount: "0.01", remark_to: EVIL, remark_data: "0xa9059cbb" }, "0x")
    end
  end

  test "金额小数位超过精度被拒" do
    assert_rejected { MultisigIntent.validate_proposal!("transfer", { to: BOB, amount: "0.#{"1" * 19}" }, "0x") }
  end

  # ── 快照 ──

  def snapshot(**overrides)
    { "sender" => SAFE, "chainId" => 10, "nonce" => "7", "callData" => VECTORS[:eth] }.merge(overrides.transform_keys(&:to_s))
  end

  def validate(snap, tx_type: "transfer", detail: { to: BOB, amount: "0.01" }, data: "0x", nonce: "7")
    MultisigIntent.validate_snapshot!(snap, safe_address: SAFE.downcase, chain_id: 10, nonce: nonce,
                                            tx_type: tx_type, call_detail: detail, evm_call_data: data)
  end

  test "与提案一致的快照通过" do
    validate(snapshot)
    validate(snapshot(callData: VECTORS[:erc20]), tx_type: "erc20_transfer",
             detail: { to: BOB, amount: "1.234567", token_address: USDC }, data: VECTORS[:erc20_data])
    validate(snapshot(callData: VECTORS[:cancel]), tx_type: "cancel", detail: {}, data: "0x")
  end

  test "篡改快照的任一关键字段被拒" do
    evil_call = "0x" + MultisigIntent.encode_safe_call_data(EVIL, 10**20, "")
    assert_rejected { validate(snapshot(callData: evil_call)) }
    assert_rejected { validate(snapshot(sender: EVIL)) }
    assert_rejected { validate(snapshot(chainId: 42161)) }
    assert_rejected { validate(snapshot(nonce: "8")) }
    assert_rejected { validate(snapshot(nonce: nil), nonce: "") }
    # 拒签：展示「拒绝」，快照却在执行转账
    assert_rejected { validate(snapshot, tx_type: "cancel", detail: {}, data: "0x") }
  end
end
