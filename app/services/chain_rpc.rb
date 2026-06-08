# frozen_string_literal: true

# 后端链上 RPC 调用服务，用于验证前端提交的链上数据真实性
# 支持 Safe 合约的 getOwners / getThreshold / getTransactionReceipt
class ChainRpc
  ALCHEMY_API_KEY = ENV.fetch("ALCHEMY_API_KEY")

  # chain_id -> Alchemy RPC URL (same key as VITE_ALCHEMY_API_KEY in semi-app)
  RPC_URLS = {
    1 => "https://eth-mainnet.g.alchemy.com/v2/#{ALCHEMY_API_KEY}",
    10 => "https://opt-mainnet.g.alchemy.com/v2/#{ALCHEMY_API_KEY}",
    11155111 => "https://eth-sepolia.g.alchemy.com/v2/#{ALCHEMY_API_KEY}"
  }.freeze

  # Safe 合约 v1.4.1 函数选择器
  SAFE_GET_OWNERS = "0xa0e67e2b"   # getOwners()
  SAFE_GET_THRESHOLD = "0xe75235b8" # getThreshold()

  # 从链上读取 Safe 合约的 owner 列表
  def self.get_owners(safe_address, chain_id)
    result = eth_call(safe_address, SAFE_GET_OWNERS, chain_id)
    decode_address_array(result)
  end

  # 从链上读取 Safe 合约的 threshold
  def self.get_threshold(safe_address, chain_id)
    result = eth_call(safe_address, SAFE_GET_THRESHOLD, chain_id)
    # threshold 是 uint256，取前 32 字节
    result[0, 64].to_i(16)
  end

  # 获取交易 receipt，验证交易是否真实执行
  def self.get_transaction_receipt(tx_hash, chain_id)
    response = rpc_request(chain_id, {
      jsonrpc: "2.0",
      method: "eth_getTransactionReceipt",
      params: [tx_hash],
      id: 1
    })
    response&.dig("result")
  end

  private

  # eth_call 读取合约数据
  def self.eth_call(to, data, chain_id)
    response = rpc_request(chain_id, {
      jsonrpc: "2.0",
      method: "eth_call",
      params: [{ to: to, data: "0x#{data}" }, "latest"],
      id: 1
    })
    response&.dig("result")&.sub(/\A0x/, "") || ""
  end

  # 解码 Solidity address[] 返回值
  def self.decode_address_array(hex_data)
    return [] if hex_data.length < 128

    # 动态数组：前 32 字节是 offset，接下来 32 字节是长度，然后每个元素 32 字节
    offset = hex_data[0, 64].to_i(16) * 2
    count = hex_data[offset, 64].to_i(16)
    addresses = []
    count.times do |i|
      addr_hex = hex_data[offset + 64 + i * 64, 64]
      # address 是右对齐的，取后 40 个字符
      addresses << "0x#{addr_hex[-40..].downcase}" if addr_hex
    end
    addresses
  end

  # 发送 JSON-RPC 请求
  def self.rpc_request(chain_id, payload)
    url = RPC_URLS[chain_id]
    raise "No RPC URL configured for chain_id=#{chain_id}" unless url

    require "net/http"
    require "json"

    uri = URI(url)
    http = Net::HTTP.new(uri.host, uri.port)
    http.use_ssl = uri.scheme == "https"
    http.read_timeout = 10
    http.open_timeout = 5

    request = Net::HTTP::Post.new(uri.path || "/", {
      "Content-Type" => "application/json"
    })
    request.body = JSON.generate(payload)

    response = http.request(request)
    JSON.parse(response.body)
  rescue => e
    Rails.logger.error("ChainRpc request failed: #{e.message}")
    nil
  end
end
