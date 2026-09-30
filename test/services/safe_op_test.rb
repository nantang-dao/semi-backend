require "test_helper"

# 向量由 viem 生成（hashTypedData / getUserOperationHash / signTypedData），
# 见 test/fixtures/files/safe_op_vectors.json：一份带 factory + paymaster（OP），
# 一份不带、nonce 带 key、有 validAfter / validUntil（Arbitrum）。
class SafeOpTest < ActiveSupport::TestCase
  VECTORS = JSON.parse(File.read(Rails.root.join("test/fixtures/files/safe_op_vectors.json")))

  test "safe_op_hash matches viem" do
    VECTORS.each { |v| assert_equal v["safeOpHash"], SafeOp.safe_op_hash(v["snapshot"]) }
  end

  test "user_op_hash matches viem" do
    VECTORS.each { |v| assert_equal v["userOpHash"], SafeOp.user_op_hash(v["snapshot"]) }
  end

  test "recover_signer returns the address that signed the SafeOp" do
    VECTORS.each do |v|
      v["signatures"].each do |s|
        assert_equal s["signer"], SafeOp.recover_signer(v["safeOpHash"], s["signature"])
      end
    end
  end

  test "any change to the snapshot changes both hashes" do
    v = VECTORS.first
    tampered = v["snapshot"].merge("maxFeePerGas" => (v["snapshot"]["maxFeePerGas"].to_i + 1).to_s)
    assert_not_equal v["safeOpHash"], SafeOp.safe_op_hash(tampered)
    assert_not_equal v["userOpHash"], SafeOp.user_op_hash(tampered)
  end

  test "a signature over another hash recovers someone else" do
    v = VECTORS.first
    sig = v["signatures"].first
    other = VECTORS.last["safeOpHash"]
    assert_not_equal sig["signer"], SafeOp.recover_signer(other, sig["signature"])
  end

  test "test keys sign SafeOp hashes the way viem does" do
    key = EvmTestKey.new("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d")
    assert_equal VECTORS.first["signatures"].first["signer"], key.address
    hash = VECTORS.first["safeOpHash"]
    assert_equal key.address, SafeOp.recover_signer(hash, key.sign_digest(hash))
  end

  test "malformed signatures recover nobody" do
    hash = VECTORS.first["safeOpHash"]
    good = VECTORS.first["signatures"].first["signature"]
    assert_nil SafeOp.recover_signer(hash, "0x")
    assert_nil SafeOp.recover_signer(hash, "0x" + "00" * 65)
    assert_nil SafeOp.recover_signer(hash, good[0..-3] + "00") # v = 0：合约签名，Semi 不用
    assert_nil SafeOp.recover_signer(hash, good[0..-3] + "20") # v > 30：eth_sign 形式，Semi 不用
  end

  test "malformed snapshots raise" do
    snapshot = VECTORS.first["snapshot"]
    assert_raises(SafeOp::InvalidSnapshot) { SafeOp.safe_op_hash(snapshot.merge("nonce" => "-1")) }
    assert_raises(SafeOp::InvalidSnapshot) { SafeOp.safe_op_hash(snapshot.merge("callData" => "0x123")) }
    assert_raises(SafeOp::InvalidSnapshot) { SafeOp.user_op_hash(snapshot.merge("sender" => "0x1234")) }
  end
end
