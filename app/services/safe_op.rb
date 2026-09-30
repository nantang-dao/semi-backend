# 多签快照（user_op_snapshot）的两个哈希，以及签名人恢复。
#
# - safe_op_hash：每个 owner 实际签下去的 SafeOp EIP-712 哈希（semi-core multisig/sign.ts
#   的 safeOpTypedData）。收签名时用它恢复签名人，签名对不上就拒收。
# - user_op_hash：EntryPoint v0.7 给这笔 UserOp 的哈希（semi-core multisig/execute.ts
#   提交的那一份）。确认执行时，回执里必须有这个哈希的 UserOperationEvent。
#
# 两者都由后端从快照自己算，不采信前端传来的哈希。算法由 viem 生成的向量锁住
# （test/fixtures/files/safe_op_vectors.json）。快照字段是跨进程契约，见 semi-core
# multisig/types.ts。
module SafeOp
  class InvalidSnapshot < StandardError; end

  ENTRY_POINT = "0x0000000071727de22e5e9d8baf0edac6f37da032"
  SAFE_4337_MODULE = "0x75cf11467937ce3f2f357ce24ffc3dbf8fd5c226"

  SAFE_OP_TYPE = "SafeOp(address safe,uint256 nonce,bytes initCode,bytes callData,uint128 verificationGasLimit," \
                 "uint128 callGasLimit,uint256 preVerificationGas,uint128 maxPriorityFeePerGas,uint128 maxFeePerGas," \
                 "bytes paymasterAndData,uint48 validAfter,uint48 validUntil,address entryPoint)"
  DOMAIN_TYPE = "EIP712Domain(uint256 chainId,address verifyingContract)"

  # secp256k1 的域和阶
  P = OpenSSL::BN.new("fffffffffffffffffffffffffffffffffffffffffffffffffffffffefffffc2f", 16)
  N = OpenSSL::BN.new("fffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141", 16)
  GROUP = OpenSSL::PKey::EC::Group.new("secp256k1")

  module_function

  def safe_op_hash(snapshot)
    s = snapshot.to_h.with_indifferent_access
    domain = keccak(keccak(DOMAIN_TYPE) + uint(s[:chainId]) + address(SAFE_4337_MODULE))
    struct = keccak(
      keccak(SAFE_OP_TYPE) +
      address(s[:sender]) + uint(s[:nonce]) +
      keccak(bytes(s[:initCode])) + keccak(bytes(s[:callData])) +
      uint(s[:verificationGasLimit]) + uint(s[:callGasLimit]) + uint(s[:preVerificationGas]) +
      uint(s[:maxPriorityFeePerGas]) + uint(s[:maxFeePerGas]) +
      keccak(bytes(s[:paymasterAndData])) +
      uint(s[:validAfter]) + uint(s[:validUntil]) +
      address(ENTRY_POINT)
    )
    "0x" + keccak("\x19\x01".b + domain + struct).unpack1("H*")
  end

  # 与 execute.ts 提交给 bundler 的字段一致：initCode 由 factory + factoryData 拼出，
  # paymasterAndData 由拆开的 paymaster 字段打包。
  def user_op_hash(snapshot)
    s = snapshot.to_h.with_indifferent_access
    init_code = s[:factory].present? && s[:factoryData].present? ? bytes(s[:factory]) + bytes(s[:factoryData]) : "".b
    paymaster_and_data =
      if s[:paymaster].present?
        bytes(s[:paymaster]) + uint(s[:paymasterVerificationGasLimit] || 0, 16) +
          uint(s[:paymasterPostOpGasLimit] || 0, 16) + bytes(s[:paymasterData] || "0x")
      else
        "".b
      end
    packed = keccak(
      address(s[:sender]) + uint(s[:nonce]) + keccak(init_code) + keccak(bytes(s[:callData])) +
      uint(s[:verificationGasLimit], 16) + uint(s[:callGasLimit], 16) +
      uint(s[:preVerificationGas]) +
      uint(s[:maxPriorityFeePerGas], 16) + uint(s[:maxFeePerGas], 16) +
      keccak(paymaster_and_data)
    )
    "0x" + keccak(packed + address(ENTRY_POINT) + uint(s[:chainId])).unpack1("H*")
  end

  # 65 字节 r || s || v（v = 27/28，Safe 的普通 ECDSA 签名）恢复出签名地址（小写）。
  # 签名格式不对或恢复失败返回 nil。
  def recover_signer(digest_hex, signature)
    sig = signature.to_s.downcase.delete_prefix("0x")
    return nil unless sig.match?(/\A\h{130}\z/)

    r = OpenSSL::BN.new(sig[0, 64], 16)
    s = OpenSSL::BN.new(sig[64, 64], 16)
    v = sig[128, 2].to_i(16)
    return nil unless [ 27, 28 ].include?(v) && r > 0 && r < N && s > 0 && s < N && r < P

    e = OpenSSL::BN.new(digest_hex.to_s.delete_prefix("0x"), 16)
    r_point = OpenSSL::PKey::EC::Point.new(GROUP, OpenSSL::BN.new((v == 27 ? "02" : "03") + sig[0, 64], 16))
    r_inv = r.mod_inverse(N)
    u1 = ((N - (e % N)) % N).mod_mul(r_inv, N)
    u2 = s.mod_mul(r_inv, N)
    # Q = r⁻¹(sR − eG) = u2·R + u1·G
    q = r_point.mul(u2, u1)
    return nil if q.infinity?

    WalletBinding.address_from_public_key("0x" + q.to_octet_string(:uncompressed).unpack1("H*"))
  rescue OpenSSL::PKey::EC::Point::Error, OpenSSL::BNError
    nil
  end

  def keccak(data) = WalletBinding.keccak(data)

  def bytes(hex)
    str = hex.to_s
    raise InvalidSnapshot, "not hex: #{str[0, 20]}" unless str.match?(/\A0x(\h\h)*\z/i)
    [ str[2..] ].pack("H*")
  end

  def address(hex)
    raw = bytes(hex)
    raise InvalidSnapshot, "not an address" unless raw.bytesize == 20
    ("\x00" * 12).b + raw
  end

  # 无符号整数，大端补零到 size 字节（默认 32 = uint256 的 ABI 编码）
  def uint(value, size = 32)
    str = value.to_s
    raise InvalidSnapshot, "not an unsigned integer: #{str[0, 20]}" unless str.match?(/\A\d+\z/)
    int = str.to_i
    raise InvalidSnapshot, "integer too large" if int >= 2**(size * 8)
    [ int.to_s(16).rjust(size * 2, "0") ].pack("H*")
  end
end
