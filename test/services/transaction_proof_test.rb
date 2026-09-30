require "test_helper"
require "minitest/mock"

class TransactionProofTest < ActiveSupport::TestCase
  SAFE = "0x" + "5a" * 20
  OTHER_SAFE = "0x" + "6b" * 20
  RECEIVER = "0x" + "7c" * 20
  TX_HASH = "0x" + "12" * 32

  setup do
    @key = "0x" + "4d" * 20
    @user = User.create!(phone: "13800000030", evm_chain_active_key: @key, evm_chain_address: SAFE)
  end

  def event(sender, success: true, gas: 123_456)
    word = ->(n) { n.to_s(16).rjust(64, "0") }
    { "topics" => [ UserOpReceipt::EVENT_TOPIC, "0x" + "ab" * 32, "0x" + "0" * 24 + sender.delete_prefix("0x"), "0x" + "0" * 64 ],
      "data" => "0x" + word.(0) + word.(success ? 1 : 0) + word.(gas) + word.(1) }
  end

  def verify(sender: SAFE, receiver: RECEIVER, logs: [ event(SAFE) ], input: "0xdeadbeef" + "0" * 24 + RECEIVER.delete_prefix("0x"), chain: "op mainnet")
    ChainRpc.stub(:get_transaction_receipt, { "status" => "0x1", "logs" => logs }) do
      ChainRpc.stub(:get_transaction, { "input" => input }) do
        TransactionProof.verify!(user: @user, tx_hash: TX_HASH, chain: chain, sender_address: sender, receiver_address: receiver)
      end
    end
  end

  test "accepts the user's own UserOp and takes gas and status from the receipt" do
    result = verify(logs: [ event(SAFE, success: false, gas: 999) ])
    assert_equal 10, result.chain_id
    assert_equal 999, result.gas_used
    assert_not result.success
  end

  test "accepts a multisig Safe the user is a member of" do
    wallet = Wallet.create!(user: @user, name: "m", wallet_type: "multisig", chain: "10", chain_id: 10, evm_chain_address: OTHER_SAFE, threshold: 1)
    WalletOwner.create!(wallet: wallet, owner_address: @key, position: 0)
    assert verify(sender: OTHER_SAFE, logs: [ event(OTHER_SAFE) ])
  end

  test "rejects a sender that is not the user's" do
    err = assert_raises(TransactionProof::Invalid) { verify(sender: OTHER_SAFE, logs: [ event(OTHER_SAFE) ]) }
    assert_match(/not your wallet/, err.message)
  end

  test "rejects a receipt without a UserOp from the sender" do
    assert_raises(TransactionProof::Invalid) { verify(logs: [ event(OTHER_SAFE) ]) }
  end

  test "rejects a receiver that the transaction never touches" do
    err = assert_raises(TransactionProof::Invalid) { verify(input: "0xdeadbeef") }
    assert_match(/receiver_address/, err.message)
  end

  test "finds the receiver in logs too, and allows no receiver" do
    log = { "topics" => [ "0x" + "ee" * 32, "0x" + "0" * 24 + RECEIVER.delete_prefix("0x") ], "data" => "0x" }
    assert verify(input: "0x", logs: [ event(SAFE), log ])
    assert verify(receiver: "", input: "0x")
  end

  test "unknown chains and missing transactions are refused" do
    assert_raises(TransactionProof::Invalid) { verify(chain: "evm") }
    ChainRpc.stub(:get_transaction_receipt, nil) do
      TransactionProof.stub(:sleep, nil) do
        assert_raises(TransactionProof::Unavailable) do
          TransactionProof.verify!(user: @user, tx_hash: TX_HASH, chain: "op mainnet", sender_address: SAFE, receiver_address: "")
        end
      end
    end
  end
end
