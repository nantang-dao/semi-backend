# 用户上传的交易记录（add_transaction / add_transaction_with_gas_credits）必须对得上链上回执。
#
# 曾经原样保存：任何人都能以任意发送方、给任意收款方写一条从没发生过的记录，出现在对方的
# 收款记录里（附带钓鱼备注）；gas_used 由前端填，可以是负数，直接累加进 gas 额度。
#
# 现在要求：
# - 回执里有 sender_address 这个 Safe 的 UserOperationEvent；
# - sender_address 是上传者自己的 Safe，或上传者当前是成员的多签 Safe；
# - receiver_address（有的话）出现在这笔交易的调用数据或日志里（转账目标、ERC20 收款人、
#   部署时的工厂合约都在 handleOps 的调用数据里）。
# gas 和成败取自该事件（actualGasCost、success），不用前端的值。
#
# 只校验新上传的记录，历史记录不动。
module TransactionProof
  class Invalid < StandardError; end
  class Unavailable < StandardError; end

  Result = Struct.new(:chain_id, :gas_used, :success, keyword_init: true)

  # 前端传的是 viem 链名的小写（`chain.name.toLowerCase()`），早期记录里也有 chain id
  CHAIN_IDS = {
    "op mainnet" => 10, "optimism" => 10, "10" => 10,
    "arbitrum one" => 42161, "arbitrum" => 42161, "42161" => 42161,
    "ethereum" => 1, "mainnet" => 1, "1" => 1,
    "sepolia" => 11155111, "11155111" => 11155111
  }.freeze

  module_function

  def verify!(user:, tx_hash:, chain:, sender_address:, receiver_address:)
    chain_id = CHAIN_IDS[chain.to_s.strip.downcase]
    raise Invalid, "unsupported chain #{chain.inspect}" unless chain_id
    raise Invalid, "tx_hash is invalid" unless tx_hash.to_s.match?(/\A0x\h{64}\z/)

    sender = sender_address.to_s.downcase
    raise Invalid, "sender_address is not your wallet" unless sender_allowed?(user, sender)

    receipt = fetch_with_retry { ChainRpc.get_transaction_receipt(tx_hash, chain_id) }
    padded = "0x" + "0" * 24 + sender.delete_prefix("0x")
    event = (receipt["logs"] || []).find do |log|
      topics = (log["topics"] || []).map { |t| t.to_s.downcase }
      topics[0] == UserOpReceipt::EVENT_TOPIC && topics[2] == padded
    end
    raise Invalid, "the transaction has no UserOperation from sender_address" unless event

    receiver = receiver_address.to_s.downcase.delete_prefix("0x")
    if receiver.present?
      raise Invalid, "receiver_address is not an address" unless receiver.match?(/\A\h{40}\z/)
      tx = fetch_with_retry { ChainRpc.get_transaction(tx_hash, chain_id) }
      haystack = ([ tx["input"] ] + (receipt["logs"] || []).flat_map { |l| (l["topics"] || []) + [ l["data"] ] }).join.downcase
      raise Invalid, "receiver_address does not appear in the transaction" unless haystack.include?(receiver)
    end

    Result.new(chain_id: chain_id, gas_used: UserOpReceipt.actual_gas_cost(event), success: UserOpReceipt.success?(event))
  end

  def sender_allowed?(user, sender)
    return false unless sender.match?(/\A0x\h{40}\z/)
    return true if user.evm_chain_address.to_s.downcase == sender

    key = user.evm_chain_active_key.to_s.downcase
    return false if key.blank?

    WalletOwner.joins(:wallet)
               .where(wallets: { wallet_type: "multisig" })
               .where("LOWER(wallets.evm_chain_address) = ?", sender)
               .where("LOWER(wallet_owners.owner_address) = ?", key)
               .exists?
  end

  # 刚上链的交易，节点可能还差一个块：短暂重试，仍读不到就报不可用（前端稍后重传）
  def fetch_with_retry(attempts: 3, wait: 1.5)
    attempts.times do |i|
      result = yield
      return result if result
      sleep(wait) if i < attempts - 1
    end
    raise Unavailable, "transaction not found on chain yet"
  end
end
