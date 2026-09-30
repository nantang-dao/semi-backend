# 把用户的签名私钥（evm_chain_active_key）和 Safe 地址（evm_chain_address）绑定到账户前的校验。
#
# 这两个字段决定了「谁是这个地址的主人」：交易记录按地址匹配，多签按
# evm_chain_active_key 识别 owner。以前前端报什么后端存什么，任何人都能把别人的
# 私钥地址或 Safe 地址报成自己的。现在要求：
#
# 1. 持有私钥：对 binding_message 的 personal_sign（EIP-191），用随附的公钥验签，
#    公钥 keccak 出来的地址必须就是 evm_chain_active_key。消息里带着账户 id，签名
#    不能拿去给别的账户用。
# 2. Safe 地址由这把私钥推出：单 owner、门限 1、saltNonce 0 的 Safe v1.4.1 地址，
#    与 semi-core predictAddress(ctx, { owner }) 一致（各链相同）。
#
# 常量由 semi-core 生成，见 test/services/wallet_binding_test.rb 的向量。
module WalletBinding
  class InvalidProof < StandardError; end

  SAFE_PROXY_FACTORY = "4e1dcf7ad4e460cfd30791ccc4f9c8a4f820ec67".freeze
  # keccak256(proxyCreationCode ++ uint256(Safe v1.4.1 singleton))
  SAFE_INIT_CODE_HASH = "76733d705f71b79841c0ee960a0ca880f779cde7ef446c989e6d23efc0a4adfb".freeze
  # encodeSafeInitializer({ owners: [owner], threshold: 1 })：owner 只出现一次，前后固定
  SAFE_INITIALIZER_PREFIX = [
    "b63e800d0000000000000000000000000000000000000000000000000000000000000100000000000000000000000000",
    "000000000000000000000000000000000000000100000000000000000000000038869bf66a61cf6bdb996a6ae40d5853",
    "fd43b5260000000000000000000000000000000000000000000000000000000000000140000000000000000000000000",
    "75cf11467937ce3f2f357ce24ffc3dbf8fd5c22600000000000000000000000000000000000000000000000000000000",
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
    "000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000",
    "00000001000000000000000000000000"
  ].join.freeze
  SAFE_INITIALIZER_SUFFIX = [
    "00000000000000000000000000000000000000000000000000000000000001048d80ff0a000000000000000000000000",
    "000000000000000000000000000000000000002000000000000000000000000000000000000000000000000000000000",
    "000000b9012dd68b007b46fbe91b9a7c3eda5a7a1063cb5b470000000000000000000000000000000000000000000000",
    "00000000000000000000000000000000000000000000000000000000000000000000000000000000648d0dc49f000000",
    "000000000000000000000000000000000000000000000000000000002000000000000000000000000000000000000000",
    "0000000000000000000000000100000000000000000000000075cf11467937ce3f2f357ce24ffc3dbf8fd5c226000000",
    "0000000000000000000000000000000000000000000000000000000000000000"
  ].join.freeze

  ADDRESS_RE = /\A0x[0-9a-fA-F]{40}\z/

  module_function

  # 前端签的就是这句话，改动它要同步 semi-app/utils/wallet_binding.ts
  def binding_message(user_id, active_key, safe_address)
    "Semi: bind signing key #{active_key.to_s.downcase} and wallet #{safe_address.to_s.downcase} to account #{user_id}"
  end

  def verify!(user_id:, active_key:, safe_address:, public_key:, signature:)
    raise InvalidProof, "evm_chain_active_key must be an address" unless active_key.to_s.match?(ADDRESS_RE)
    raise InvalidProof, "evm_chain_address must be an address" unless safe_address.to_s.match?(ADDRESS_RE)
    unless address_from_public_key(public_key) == active_key.downcase
      raise InvalidProof, "public_key does not belong to evm_chain_active_key"
    end
    unless signature_valid?(public_key, binding_message(user_id, active_key, safe_address), signature)
      raise InvalidProof, "signature does not prove ownership of evm_chain_active_key"
    end
    unless predict_safe_address(active_key) == safe_address.downcase
      raise InvalidProof, "evm_chain_address is not the Safe derived from evm_chain_active_key"
    end
  end

  def predict_safe_address(owner)
    initializer = [ SAFE_INITIALIZER_PREFIX + owner.to_s.downcase.delete_prefix("0x") + SAFE_INITIALIZER_SUFFIX ].pack("H*")
    salt = keccak(keccak(initializer) + ("\x00" * 32).b)
    preimage = [ "ff" + SAFE_PROXY_FACTORY ].pack("H*") + salt + [ SAFE_INIT_CODE_HASH ].pack("H*")
    "0x" + keccak(preimage).unpack1("H*")[24, 40]
  end

  # 未压缩公钥 0x04 || X || Y
  def address_from_public_key(public_key)
    hex = public_key.to_s.downcase.delete_prefix("0x")
    raise InvalidProof, "public_key must be an uncompressed secp256k1 key" unless hex.match?(/\A04[0-9a-f]{128}\z/)
    "0x" + keccak([ hex[2..] ].pack("H*")).unpack1("H*")[24, 40]
  end

  # 65 字节 r || s || v 的 EIP-191 签名。已知公钥，直接用 OpenSSL 验，不做公钥恢复。
  def signature_valid?(public_key, message, signature)
    sig = signature.to_s.downcase.delete_prefix("0x")
    return false unless sig.match?(/\A[0-9a-f]{130}\z/)

    point = [ public_key.to_s.downcase.delete_prefix("0x") ].pack("H*")
    spki = OpenSSL::ASN1::Sequence([
      OpenSSL::ASN1::Sequence([ OpenSSL::ASN1::ObjectId("id-ecPublicKey"), OpenSSL::ASN1::ObjectId("secp256k1") ]),
      OpenSSL::ASN1::BitString(point)
    ])
    key = OpenSSL::PKey::EC.new(spki.to_der)
    der = OpenSSL::ASN1::Sequence([
      OpenSSL::ASN1::Integer(OpenSSL::BN.new(sig[0, 64], 16)),
      OpenSSL::ASN1::Integer(OpenSSL::BN.new(sig[64, 64], 16))
    ]).to_der
    digest = keccak("\x19Ethereum Signed Message:\n#{message.bytesize}".b + message.b)
    key.dsa_verify_asn1(digest, der)
  rescue OpenSSL::PKey::PKeyError, OpenSSL::ASN1::ASN1Error
    false
  end

  def keccak(bytes)
    Digest::Keccak.new(256).digest(bytes)
  end
end
