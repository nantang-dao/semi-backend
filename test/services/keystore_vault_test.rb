require "test_helper"

class KeystoreVaultTest < ActiveSupport::TestCase
  VERIFIER = "ab" * 32
  KEY_SHARE = "cd" * 32
  V2 = { version: 2, crypto: { ciphertext: "AAAA", iv: "00" * 12, salt: "11" * 16, kdf: "pbkdf2",
                               cipher: "aes-gcm", iterations: 100_000, hash: "SHA-256", keyShare: true } }.to_json

  setup do
    @user = User.create!(phone: "13800000040")
    KeystoreVault.assign_v2(@user, encrypted_keys: V2, verifier: VERIFIER, key_share: KEY_SHARE)
    @user.save!
  end

  test "stores neither the verifier nor the key_share in the clear" do
    assert_equal 2, KeystoreVault.version(@user)
    assert_not_includes @user.keystore_verifier_mac, VERIFIER
    assert_not_includes @user.key_share_ciphertext, KEY_SHARE
    assert_not_includes Base64.decode64(@user.key_share_ciphertext.split(":", 2).last).unpack1("H*"), KEY_SHARE
  end

  test "the right verifier gets the key_share and resets the failure count" do
    @user.update!(keystore_failed_attempts: 4)
    assert_equal KEY_SHARE, KeystoreVault.unlock!(@user, VERIFIER)
    assert_equal 0, @user.reload.keystore_failed_attempts
  end

  test "wrong verifiers are counted and lock the keystore at 10, even for the right one" do
    9.times do |i|
      err = assert_raises(KeystoreVault::BadPasscode) { KeystoreVault.unlock!(@user, "00" * 32) }
      assert_equal 9 - i, err.attempts_left
    end
    assert_equal 9, @user.reload.keystore_failed_attempts
    assert_raises(KeystoreVault::Locked) { KeystoreVault.unlock!(@user, "00" * 32) }
    assert_raises(KeystoreVault::Locked) { KeystoreVault.unlock!(@user, VERIFIER) }

    travel KeystoreVault::LOCK_DURATION + 1.minute do
      assert_equal KEY_SHARE, KeystoreVault.unlock!(@user.reload, VERIFIER)
    end
  end

  test "a key_share ciphertext copied to another user does not decrypt" do
    other = User.create!(phone: "13800000041")
    other.update!(keystore_verifier_mac: KeystoreVault.mac(other.id, VERIFIER), key_share_ciphertext: @user.key_share_ciphertext)
    assert_raises(OpenSSL::Cipher::CipherError) { KeystoreVault.unlock!(other, VERIFIER) }
  end

  test "only well-formed v2 keystores are accepted" do
    assert_nothing_raised { KeystoreVault.validate_v2!(V2, VERIFIER, KEY_SHARE) }
    bad = JSON.parse(V2)
    [
      [ { "version" => 1 }, VERIFIER, KEY_SHARE ],
      [ bad.deep_merge("crypto" => { "keyShare" => false }), VERIFIER, KEY_SHARE ],
      [ bad.deep_merge("crypto" => { "iterations" => 1000 }), VERIFIER, KEY_SHARE ],
      [ bad, "12", KEY_SHARE ],
      [ bad, VERIFIER, "zz" * 32 ]
    ].each do |ks, verifier, share|
      assert_raises(KeystoreVault::Invalid) { KeystoreVault.validate_v2!(ks.to_json, verifier, share) }
    end
  end

  # 由 semi-app utils/keystore_message.ts + viem signMessage 生成（私钥 0x…01）。前端签、后端验，
  # 消息格式必须逐字一致。
  VIEM_UPDATE = {
    encrypted_keys: '{"version":2,"crypto":{"ciphertext":"AAAA","iv":"000000000000000000000000","salt":"11111111111111111111111111111111","kdf":"pbkdf2","cipher":"aes-gcm","iterations":100000,"hash":"SHA-256","keyShare":true}}',
    message: "Semi: update keystore of account 3testuser0001 at 1790000000 sha256:63bcc0aa2c5291bf075686ff19968d44edd84cdb087f93ba8ba85e06e2e74639",
    public_key: "0x0479be667ef9dcbbac55a06295ce870b07029bfcdb2dce28d959f2815b16f81798483ada7726a3c4655da4fbfc0e1108a8fd17b448a68554199c47d08ffb10d4b8",
    signature: "0x3b63fecc7d2626d59937a526f793aecb0ec0375dd71013c64d8133a6c8afecef5a0f155a5e982354060e508e1f710091952d5e8b06659b2ac1aa22f99b128c8f1b"
  }.freeze

  test "accepts an update signed by viem with the frontend's message" do
    assert_equal VIEM_UPDATE[:message], KeystoreVault.update_message("3testuser0001", 1_790_000_000, VIEM_UPDATE[:encrypted_keys], VERIFIER, KEY_SHARE)

    user = User.new(id: "3testuser0001", evm_chain_active_key: "0x7E5F4552091A69125d5DfCb7b8C2659029395Bdf")
    travel_to Time.at(1_790_000_000) do
      assert_nothing_raised do
        KeystoreVault.validate_v2!(VIEM_UPDATE[:encrypted_keys], VERIFIER, KEY_SHARE)
        KeystoreVault.verify_update!(user, issued_at: "1790000000", public_key: VIEM_UPDATE[:public_key], signature: VIEM_UPDATE[:signature],
                                     encrypted_keys: VIEM_UPDATE[:encrypted_keys], verifier: VERIFIER, key_share: KEY_SHARE)
      end
    end
  end
end
