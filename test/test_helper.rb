ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
require "rails/test_help"

# 测试里用的以太坊私钥：OpenSSL 生成 secp256k1 密钥并做 personal_sign，
# 与 viem 的实现互相独立（viem 的签名向量见 test/services/wallet_binding_test.rb）。
class EvmTestKey
  attr_reader :public_key, :address

  # 不给私钥就随机生成；给了（0x 开头的 32 字节 hex）就用它，地址可预知
  def initialize(private_key = nil)
    @key = private_key ? self.class.key_from_private(private_key) : OpenSSL::PKey::EC.generate("secp256k1")
    @public_key = "0x" + @key.public_key.to_octet_string(:uncompressed).unpack1("H*")
    @address = WalletBinding.address_from_public_key(@public_key)
  end

  def self.key_from_private(hex)
    group = OpenSSL::PKey::EC::Group.new("secp256k1")
    priv = OpenSSL::BN.new(hex.delete_prefix("0x"), 16)
    der = OpenSSL::ASN1::Sequence([
      OpenSSL::ASN1::Integer(1),
      OpenSSL::ASN1::OctetString([ hex.delete_prefix("0x").rjust(64, "0") ].pack("H*")),
      OpenSSL::ASN1::ObjectId("secp256k1").tap { |o| o.tagging = :EXPLICIT; o.tag = 0; o.tag_class = :CONTEXT_SPECIFIC },
      OpenSSL::ASN1::BitString(group.generator.mul(priv).to_octet_string(:uncompressed)).tap { |b| b.tagging = :EXPLICIT; b.tag = 1; b.tag_class = :CONTEXT_SPECIFIC }
    ])
    OpenSSL::PKey::EC.new(der.to_der)
  end

  # 直接对 32 字节摘要签名（SafeOp 的 EIP-712 哈希），v 取能恢复出本地址的那个
  def sign_digest(digest_hex)
    digest = [ digest_hex.delete_prefix("0x") ].pack("H*")
    r, s = OpenSSL::ASN1.decode(@key.dsa_sign_asn1(digest)).value.map { |i| i.value.to_s(16).rjust(64, "0") }
    %w[1b 1c].map { |v| "0x#{r}#{s}#{v}" }.find { |sig| SafeOp.recover_signer(digest_hex, sig) == address }
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
