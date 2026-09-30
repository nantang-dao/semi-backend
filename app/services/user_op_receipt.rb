# frozen_string_literal: true

# ERC-4337 回执的解读。
#
# 存在的理由只有一条：**打包交易成功 ≠ 这笔 UserOperation 成功**。
# EntryPoint 会 catch 住内层调用的 revert，handleOps 照样返回 status 0x1，
# 回执照样有 transactionHash。成败写在 UserOperationEvent 的 success 位里。
#
# 不查这一位的后果：一笔转账失败的多签会被标记成 executed，配置类交易还会
# 顺带把 owner/threshold 的镜像改掉 —— 而链上根本没变。gas 扣了，nonce 消耗了，
# 钱没动，所有人都以为成了。
class UserOpReceipt
  # keccak("UserOperationEvent(bytes32,address,address,uint256,bool,uint256,uint256)")
  # topics: [sig, userOpHash, sender, paymaster]
  # data:   nonce(32) | success(32) | actualGasCost(32) | actualGasUsed(32)
  EVENT_TOPIC = "0x49628fd1471006c1482da88028e9ce4dbb080b815c9b0344d39e5a8e6ec1419f"

  class NotFound < StandardError; end
  class Reverted < StandardError; end

  # @param logs [Array<Hash>] 回执里的 logs
  # @param padded_sender [String] 左补零到 32 字节的 Safe 地址（小写）
  # @param user_op_hash [String] 后端从快照算出的哈希（SafeOp.user_op_hash），必填。
  #   曾经可选、缺省时按 sender 匹配 —— 同一 Safe 的任意旧回执都能通过。
  # @raise [NotFound] 读不出对应的事件 —— 失败闭合，宁可让前端重试也不猜它成功
  # @raise [Reverted] UserOp 上链了但内层调用回滚
  def self.assert_succeeded!(logs, padded_sender, user_op_hash)
    raise ArgumentError, "user_op_hash is required" if user_op_hash.blank?

    events = (logs || []).select do |log|
      topics = (log["topics"] || []).map { |t| t.to_s.downcase }
      topics[0] == EVENT_TOPIC && topics[2] == padded_sender
    end

    # 先判「这份回执里根本没有本 Safe 的 UserOp」，再按 hash 筛。两种情况的
    # 排查方向完全不同（前者多半是回执认错了，后者是这份回执执行的不是这笔交易）。
    raise NotFound, "回执中没有本数字身份的 UserOperationEvent" if events.empty?

    wanted = user_op_hash.to_s.downcase
    event = events.find { |log| log["topics"][1].to_s.downcase == wanted }
    raise NotFound, "回执中找不到这笔交易的 UserOp" unless event
    raise Reverted, "链上执行失败（UserOp 已上链但内层调用回滚）" unless success?(event)
  end

  # data 的第二个字（32..63 字节）是 bool success。
  # 读不出来（data 太短）就当失败 —— 看不懂的回执不该被判成成功。
  def self.success?(log)
    data = log["data"].to_s.sub(/\A0x/, "")
    return false if data.length < 128

    data[64, 64].to_i(16) == 1
  end
end
