require "bigdecimal"

# 多签交易「展示内容（call_detail）⇄ 调用数据（evm_call_data）⇄ 快照（user_op_snapshot）」
# 三者的一致性校验。
#
# 页面给签名人看的是 call_detail，链上执行的是快照里的 callData。两者之间任何一处
# 不核对，提案人或第一个签名人就能让其他 owner 看着「转 0.01」签下「转走全部」。
# 前端签名前也会做同样的核对（semi-app/utils/multisig_calls.ts +
# semi-core/src/multisig/intent.ts）；这里是后端这一道：不合的提案和快照根本存不进来，
# 这样还没刷新到新版前端的签名人也受保护。
#
# 每笔多签交易只执行**一个** CALL（operation 0）。旧版 transfer 页会附加一个 remark
# 调用（call_detail.remark_to / remark_data），签名人看不到它，现在一律拒绝。
module MultisigIntent
  # executeUserOpWithErrorString(address,uint256,bytes,uint8)
  EXECUTE_SELECTOR = "541d63c8".freeze
  # transfer(address,uint256)
  ERC20_TRANSFER_SELECTOR = "a9059cbb".freeze
  # Safe v1.4.1 OwnerManager
  ADD_OWNER_SELECTOR = "0d582f13".freeze        # addOwnerWithThreshold(address,uint256)
  REMOVE_OWNER_SELECTOR = "f8dc5dd9".freeze     # removeOwner(address,address,uint256)
  SWAP_OWNER_SELECTOR = "e318b52b".freeze       # swapOwner(address,address,address)
  CHANGE_THRESHOLD_SELECTOR = "694e80c3".freeze # changeThreshold(uint256)

  ADDRESS_RE = /\A0x[0-9a-fA-F]{40}\z/
  AMOUNT_RE = /\A\d+(\.\d+)?\z/

  module_function

  # 提案时调用：evm_call_data 必须就是 call_detail 编码出来的那一个调用。
  def validate_proposal!(tx_type, call_detail, evm_call_data)
    detail = indifferent(call_detail)
    if detail[:remark_to].present? || detail[:remark_data].present?
      raise AppError.new("Multisig transactions cannot carry extra calls (remark_to / remark_data)", code: "intent_mismatch")
    end

    stored = normalize_hex(evm_call_data)

    case tx_type
    when "transfer", "cancel"
      raise mismatch("evm_call_data must be empty for #{tx_type}") unless stored == ""
      if tx_type == "transfer"
        address!(detail[:to], "to")
        to_units(amount!(detail[:amount]), 18)
      end
    when "erc20_transfer"
      address!(detail[:token_address], "token_address")
      to = address!(detail[:to], "to")
      amount = amount!(detail[:amount])
      raise mismatch("evm_call_data is not an ERC20 transfer") unless stored.length == 8 + 64 * 2 && stored.start_with?(ERC20_TRANSFER_SELECTOR)
      raise mismatch("ERC20 recipient does not match call_detail.to") unless word_address(stored[8, 64]) == to
      # decimals 以合约为准，后端拿不到；前端提案时会带上，带了就核对金额。签名前前端还会按链上 decimals 再核一次。
      if detail[:decimals].present?
        units = to_units(amount, integer!(detail[:decimals], "decimals"))
        raise mismatch("ERC20 amount does not match call_detail.amount") unless stored[8 + 64, 64].to_i(16) == units
      end
    when "add_owner", "remove_owner", "replace_owner", "change_threshold"
      raise mismatch("evm_call_data does not match call_detail for #{tx_type}") unless stored == config_call_data(tx_type, detail)
    else
      raise AppError.new("Unsupported tx_type #{tx_type}")
    end
  end

  # 快照存入前调用（第一个签名人 / 拒签提案）：签下去的必须是这笔交易本来的内容。
  # gas / paymaster 字段不在这里核对：它们决定谁付费、付多少，不改变 Safe 执行什么。
  def validate_snapshot!(snapshot, safe_address:, chain_id:, nonce:, tx_type:, call_detail:, evm_call_data:)
    s = indifferent(snapshot)
    unless s[:sender].to_s.downcase == safe_address.to_s.downcase
      raise mismatch("user_op_snapshot.sender does not match the wallet")
    end
    unless s[:chainId].to_s == chain_id.to_s
      raise mismatch("user_op_snapshot.chainId does not match the wallet chain")
    end
    unless s[:nonce].to_s.present? && s[:nonce].to_s == nonce.to_s
      raise mismatch("user_op_snapshot.nonce does not match")
    end

    to, value, data = expected_call(tx_type, call_detail, evm_call_data, safe_address)
    unless normalize_hex(s[:callData]) == encode_safe_call_data(to, value, data)
      raise mismatch("user_op_snapshot.callData does not match the proposed transaction")
    end
  end

  # [to, value, data]。data 不带 0x，全小写。
  def expected_call(tx_type, call_detail, evm_call_data, safe_address)
    detail = indifferent(call_detail)
    case tx_type
    when "cancel"
      [ safe_address, 0, "" ]
    when "transfer"
      [ address!(detail[:to], "to"), to_units(amount!(detail[:amount]), 18), "" ]
    when "erc20_transfer"
      [ address!(detail[:token_address], "token_address"), 0, normalize_hex(evm_call_data) ]
    else
      [ safe_address, 0, config_call_data(tx_type, detail) ]
    end
  end

  # 与 semi-core encodeSafeCallData / permissionless encodeCalls([call]) 逐字节相同
  def encode_safe_call_data(to, value, data)
    data = data.to_s
    padded = data.ljust((data.length / 64.0).ceil * 64, "0")
    EXECUTE_SELECTOR +
      address_word(to) +
      uint_word(value) +
      uint_word(128) +            # data 的偏移：4 个头部字之后
      uint_word(0) +              # operation = CALL
      uint_word(data.length / 2) +
      padded
  end

  def config_call_data(tx_type, detail)
    case tx_type
    when "add_owner"
      ADD_OWNER_SELECTOR + address_word(address!(detail[:new_owner], "new_owner")) + uint_word(threshold!(detail))
    when "remove_owner"
      REMOVE_OWNER_SELECTOR + address_word(address!(detail[:prev_owner], "prev_owner")) +
        address_word(address!(detail[:owner], "owner")) + uint_word(threshold!(detail))
    when "replace_owner"
      SWAP_OWNER_SELECTOR + address_word(address!(detail[:prev_owner], "prev_owner")) +
        address_word(address!(detail[:old_owner], "old_owner")) + address_word(address!(detail[:new_owner], "new_owner"))
    when "change_threshold"
      CHANGE_THRESHOLD_SELECTOR + uint_word(threshold!(detail))
    end
  end

  # ── helpers ──

  def indifferent(hash)
    hash.is_a?(Hash) ? hash.with_indifferent_access : {}.with_indifferent_access
  end

  def normalize_hex(value)
    value.to_s.strip.downcase.delete_prefix("0x")
  end

  def address!(value, field)
    raise AppError.new("call_detail.#{field} must be an address", code: "intent_mismatch") unless value.to_s.match?(ADDRESS_RE)
    value.to_s.downcase
  end

  def amount!(value)
    amount = value.to_s.strip
    raise AppError.new("call_detail.amount is invalid", code: "intent_mismatch") unless amount.match?(AMOUNT_RE)
    amount
  end

  def integer!(value, field)
    raise AppError.new("call_detail.#{field} is invalid", code: "intent_mismatch") unless value.to_s.match?(/\A\d+\z/)
    value.to_i
  end

  def threshold!(detail)
    n = integer!(detail[:new_threshold], "new_threshold")
    raise AppError.new("call_detail.new_threshold is invalid", code: "intent_mismatch") if n < 1
    n
  end

  # 精确的十进制 → 最小单位，小数位超过 decimals 视为非法（与 viem parseUnits 不同，它会四舍五入）
  def to_units(amount, decimals)
    units = BigDecimal(amount) * (BigDecimal(10)**decimals)
    raise AppError.new("call_detail.amount has too many decimal places", code: "intent_mismatch") unless units.frac.zero?
    units.to_i
  end

  def word_address(word)
    "0x" + word.to_s[24, 40].to_s
  end

  def address_word(address)
    address.to_s.downcase.delete_prefix("0x").rjust(64, "0")
  end

  def uint_word(n)
    n.to_i.to_s(16).rjust(64, "0")
  end

  def mismatch(message)
    AppError.new(message, code: "intent_mismatch")
  end
end
