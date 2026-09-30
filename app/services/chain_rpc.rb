# frozen_string_literal: true

# 后端链上 RPC 调用服务，用于验证前端提交的链上数据真实性
# 支持 Safe 合约的 getOwners / getThreshold / getTransactionReceipt
class ChainRpc
  # RPC 不可用、节点返回 error、返回值读不懂。调用方必须失败闭合，不能当成「没数据」。
  class Error < StandardError; end

  ALCHEMY_API_KEY = ENV.fetch("ALCHEMY_API_KEY")

  # chain_id -> Alchemy RPC URL (same key as VITE_ALCHEMY_API_KEY in semi-app)
  RPC_URLS = {
    1 => "https://eth-mainnet.g.alchemy.com/v2/#{ALCHEMY_API_KEY}",
    10 => "https://opt-mainnet.g.alchemy.com/v2/#{ALCHEMY_API_KEY}",
    11155111 => "https://eth-sepolia.g.alchemy.com/v2/#{ALCHEMY_API_KEY}",
    42161 => "https://arb-mainnet.g.alchemy.com/v2/#{ALCHEMY_API_KEY}"
  }.freeze

  # Safe 合约 v1.4.1 函数选择器
  SAFE_GET_OWNERS = "0xa0e67e2b"   # getOwners()
  SAFE_GET_THRESHOLD = "0xe75235b8" # getThreshold()

  # 地址上有没有合约代码（Safe 是否已部署）
  def self.deployed?(address, chain_id)
    code = rpc_result(chain_id, "eth_getCode", [ address, "latest" ])
    code.is_a?(String) && code.sub(/\A0x/, "").present?
  end

  # 从链上读取 Safe 合约的 owner 列表（小写）。地址上没有合约时返回值为空，按错误处理。
  def self.get_owners(safe_address, chain_id)
    owners = decode_address_array(eth_call(safe_address, SAFE_GET_OWNERS, chain_id))
    raise Error, "getOwners returned no owners for #{safe_address}" if owners.empty?
    owners
  end

  # 从链上读取 Safe 合约的 threshold
  def self.get_threshold(safe_address, chain_id)
    result = eth_call(safe_address, SAFE_GET_THRESHOLD, chain_id)
    raise Error, "getThreshold returned #{result.inspect} for #{safe_address}" unless result.match?(/\A\h{64}\z/)
    result.to_i(16)
  end

  # 获取交易 receipt；还没上链或 RPC 暂时不可用都返回 nil，由调用方重试后失败闭合
  def self.get_transaction_receipt(tx_hash, chain_id)
    rpc_result(chain_id, "eth_getTransactionReceipt", [ tx_hash ])
  rescue Error => e
    Rails.logger.error("ChainRpc receipt lookup failed: #{e.message}")
    nil
  end

  private

  # eth_call 读取合约数据，返回去掉 0x 的 hex。data 是带 0x 的完整 calldata
  # （曾经在这里再拼一次 0x，发出去的是 0x0xa0e67e2b，调用一直失败）。
  def self.eth_call(to, data, chain_id)
    result = rpc_result(chain_id, "eth_call", [ { to: to, data: data }, "latest" ])
    raise Error, "eth_call returned #{result.inspect}" unless result.is_a?(String) && result.match?(/\A0x\h*\z/)
    result.delete_prefix("0x")
  end

  def self.rpc_result(chain_id, method, params)
    response = rpc_request(chain_id, { jsonrpc: "2.0", method: method, params: params, id: 1 })
    raise Error, "#{method} failed: no response" unless response.is_a?(Hash)
    raise Error, "#{method} failed: #{response["error"]}" if response["error"]
    response["result"]
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

  # 发送 JSON-RPC 请求；网络错误返回 nil
  def self.rpc_request(chain_id, payload)
    url = RPC_URLS[chain_id]
    raise Error, "No RPC URL configured for chain_id=#{chain_id}" unless url

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
