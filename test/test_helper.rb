ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# 测试里用的以太坊私钥：OpenSSL 生成 secp256k1 密钥并做 personal_sign，
# 与 viem 的实现互相独立（viem 的签名向量见 test/services/wallet_binding_test.rb）。
class EvmTestKey
  attr_reader :public_key, :address

  def initialize
    @key = OpenSSL::PKey::EC.generate("secp256k1")
    @public_key = "0x" + @key.public_key.to_octet_string(:uncompressed).unpack1("H*")
    @address = WalletBinding.address_from_public_key(@public_key)
  end

  def safe_address = WalletBinding.predict_safe_address(address)

  def personal_sign(message)
    digest = WalletBinding.keccak("\x19Ethereum Signed Message:\n#{message.bytesize}".b + message.b)
    r, s = OpenSSL::ASN1.decode(@key.dsa_sign_asn1(digest)).value.map { |i| i.value.to_s(16).rjust(64, "0") }
    "0x#{r}#{s}1b" # v 不参与验签（已知公钥）
  end

  def binding_params(user)
    {
      id: user.id, encrypted_keys: '{"version":1}', evm_chain_active_key: address, evm_chain_address: safe_address,
      public_key: public_key, signature: personal_sign(WalletBinding.binding_message(user.id, address, safe_address))
    }
  end
end

module ActiveSupport
  class TestCase
    # Run tests in parallel with specified workers
    parallelize(workers: :number_of_processors)

    # Setup all fixtures in test/fixtures/*.yml for all tests in alphabetical order.
    fixtures :all

    # Add more helper methods to be used by all tests here...
  end
end
