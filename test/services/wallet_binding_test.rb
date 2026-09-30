require "test_helper"

# 向量由 semi-app 生成：Safe 地址来自 semi-core predictAddress，绑定签名来自
# utils/wallet_binding.ts 的 signWalletBinding（viem）。前端签、后端验，两边的消息
# 格式和地址推导必须一致。
class WalletBindingTest < ActiveSupport::TestCase
  PREDICTIONS = [
    [ "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf", "0x57E9161676313588c7F373F9Cb17b00f1e65BeF0" ],
    [ "0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF", "0xaC02EDA8Bc0dd304c0Bb191ac8a07A64672a2b0b" ],
    [ "0xe239cdc5fbe977a8a141B72194D3CF8c41bC5BC6", "0x423d0D315A20083755e29B917eC3Ee6077CDf92d" ]
  ].freeze

  BINDING = {
    user_id: "3testuser0001",
    active_key: "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf",
    safe_address: "0x57E9161676313588c7F373F9Cb17b00f1e65BeF0",
    public_key: "0x0479be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8",
    signature: "0x9a63c2c3fb4de337e5f8d393c2b6097ad7e3568de6b7288de2907709f3571806349d7b177ed26433ea16caedc309630af3f84fe754a01b53bbb5fa766aaddb001c"
  }.freeze

  test "Safe 地址推导与 semi-core 一致" do
    PREDICTIONS.each { |owner, safe| assert_equal safe.downcase, WalletBinding.predict_safe_address(owner) }
  end

  # 多签：semi-core predictSafeAddress（owner 升序）。这里故意传未排序的 owner
  MULTISIG_PREDICTIONS = [
    [ [ "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf", "0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF" ], 2, "0xeFF1fF1B7782a058Afa5943EFCf75099c97A8C99" ],
    [ [ "0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF", "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf" ], 1, "0xb60880aC1bb63c889cB9E96a4106ec96cC3F5dE7" ],
    [ [ "0xe239cdc5fbe977a8a141B72194D3CF8c41bC5BC6", "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf", "0x2B5AD5c4795c026514f8317c7a215E218DcCD6cF" ], 2, "0x467820335f758A005F5fb304d380475dBF2B6383" ]
  ].freeze

  test "多签 Safe 地址推导与 semi-core 一致" do
    MULTISIG_PREDICTIONS.each do |owners, threshold, safe|
      assert_equal safe.downcase, WalletBinding.predict_safe_address(owners: owners, threshold: threshold)
    end
  end

  test "消息格式与前端一致" do
    assert_equal "Semi: bind signing key 0x7e5f4552091a69125d5dfcb7b8c2659029395bdf and wallet 0x57e9161676313588c7f373f9cb17b00f1e65bef0 to account 3testuser0001",
                 WalletBinding.binding_message(BINDING[:user_id], BINDING[:active_key], BINDING[:safe_address])
  end

  test "前端（viem）签的绑定证明通过" do
    assert_nothing_raised { WalletBinding.verify!(**BINDING) }
  end

  def assert_invalid(**overrides)
    assert_raises(WalletBinding::InvalidProof) { WalletBinding.verify!(**BINDING.merge(overrides)) }
  end

  test "签名换个账户就不成立" do
    assert_invalid(user_id: "3someoneelse0")
  end

  test "别人的 Safe 地址不行" do
    assert_invalid(safe_address: PREDICTIONS[1][1])
  end

  test "别人的私钥地址不行（公钥对不上）" do
    assert_invalid(active_key: PREDICTIONS[1][0])
  end

  test "别人的公钥 + 别人的地址，但签名不是它签的" do
    other = EvmTestKey.new
    assert_invalid(public_key: other.public_key, active_key: other.address, safe_address: other.safe_address)
  end

  test "格式不对的输入" do
    assert_invalid(signature: "0x1234")
    assert_invalid(public_key: "0x02" + "00" * 32)
    assert_invalid(safe_address: "not-an-address")
  end

  test "OpenSSL 生成的密钥也能走通（测试辅助本身可信）" do
    key = EvmTestKey.new
    message = WalletBinding.binding_message("3abc", key.address, key.safe_address)
    assert_nothing_raised do
      WalletBinding.verify!(user_id: "3abc", active_key: key.address, safe_address: key.safe_address,
                            public_key: key.public_key, signature: key.personal_sign(message))
    end
  end
end
