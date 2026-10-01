require "test_helper"
require "minitest/mock"

class HomeControllerTest < ActionDispatch::IntegrationTest
  test "should get index" do
    get root_url
    assert_response :success
    assert_equal({ "message" => "Hello, World!" }, JSON.parse(@response.body))
  end

  test "should send sms" do
    post send_sms_url, params: { phone: "13800000000" }
    assert_equal({ "result" => "ok" }, JSON.parse(@response.body))
    token = VerificationToken.find_by(context: "phone-login", sent_to: "13800000000")
    assert_match(/\A\d{6}\z/, token.code)
    assert_equal "127.0.0.1", token.ip
  end

  test "send sms rejects a malformed phone" do
    post send_sms_url, params: { phone: "1234567890" }
    assert_response :bad_request
    assert_equal "invalid_phone", JSON.parse(@response.body)["code"]
    assert_equal 0, VerificationToken.count
  end

  test "send sms is rate limited per phone" do
    post send_sms_url, params: { phone: "13800000000" }
    post send_sms_url, params: { phone: "13800000000" }
    assert_response :bad_request
    assert_equal "rate_limited", JSON.parse(@response.body)["code"]
    assert_equal 1, VerificationToken.count
  end

  test "should signin with valid code" do
    VerificationToken.create(context: "phone-login", sent_to: "13800000000", code: "123456", expires_at: Time.now + 15.minutes)
    post signin_url, params: { phone: "13800000000", code: "123456" }
    assert_response :success
    body = JSON.parse(@response.body)
    user = User.find_by(phone: "13800000000")
    assert_equal({ "result" => "ok", "auth_token" => body["auth_token"], "phone" => "13800000000", "id" => user.id, "address_type" => "phone" }, body)
  end

  test "signin locks the code after five wrong guesses" do
    VerificationToken.create(context: "phone-login", sent_to: "13800000000", code: "123456", expires_at: Time.now + 15.minutes)
    5.times do
      post signin_url, params: { phone: "13800000000", code: "000000" }
      assert_equal "invalid_code", JSON.parse(@response.body)["code"]
    end
    post signin_url, params: { phone: "13800000000", code: "123456" }
    assert_response :bad_request
    assert_equal "too_many_attempts", JSON.parse(@response.body)["code"]
    assert_nil User.find_by(phone: "13800000000")
  end

  test "password signin is not routable" do
    post "/signin_with_password", params: { phone: "1234567890", password: "12345" }
    assert_response :not_found
    assert_nil User.find_by(phone: "1234567890")
  end

  test "should set handle" do
    user = User.create(phone: "1234567890")
    post set_handle_url, params: { id: user.id, handle: "newhandle" }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success
    assert JSON.parse(@response.body).key?("result")

    get get_by_handle_url, params: { handle: "newhandle" }
    assert_response :success
    assert JSON.parse(@response.body).key?("id")
    assert JSON.parse(@response.body).key?("handle")
    assert_nil JSON.parse(@response.body)["renamed_from"]
  end

  test "first set handle has no cooldown" do
    user = User.create(phone: "1111111111")
    post set_handle_url, params: { id: user.id, handle: "firstnm" }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success
    user.reload
    assert_nil user.handle_changed_at
    assert_equal 0, user.handle_aliases.count
  end

  test "rename creates alias and sets cooldown" do
    user = User.create(phone: "1222222222", handle: "oldname1")
    token = user.gen_auth_token

    post set_handle_url, params: { id: user.id, handle: "newname1" }, headers: { "Authorization" => "Bearer #{token}" }
    assert_response :success

    user.reload
    assert_equal "newname1", user.handle
    assert user.handle_changed_at.present?
    assert_equal 1, user.handle_aliases.count
    assert_equal "oldname1", user.handle_aliases.first.alias

    get get_by_handle_url, params: { handle: "oldname1" }
    body = JSON.parse(@response.body)
    assert_equal "newname1", body["handle"]
    assert_equal "oldname1", body["renamed_from"]

    get get_by_handle_url, params: { handle: "newname1" }
    body = JSON.parse(@response.body)
    assert_nil body["renamed_from"]
  end

  test "rename rejected within cooldown" do
    user = User.create(phone: "1333333333", handle: "coolnm1", handle_changed_at: 1.day.ago)
    post set_handle_url, params: { id: user.id, handle: "coolnm2" }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :bad_request
    assert_match(/Cannot rename handle within 30 days/, JSON.parse(@response.body)["message"])
  end

  test "rename rejected when unchanged" do
    user = User.create(phone: "1444444444", handle: "samehdl")
    post set_handle_url, params: { id: user.id, handle: "samehdl" }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :bad_request
    assert_equal "handle unchanged", JSON.parse(@response.body)["message"]
  end

  test "reserved alias blocks others" do
    owner = User.create(phone: "1555555555", handle: "takenow", handle_changed_at: 31.days.ago)
    owner.handle_aliases.create!(alias: "reserved1", expires_at: 30.days.from_now)
    other = User.create(phone: "1666666666", handle: "othernm", handle_changed_at: 31.days.ago)

    post set_handle_url, params: { id: other.id, handle: "reserved1" }, headers: { "Authorization" => "Bearer #{other.gen_auth_token}" }
    assert_response :bad_request
    assert_equal "handle temporarily unavailable", JSON.parse(@response.body)["message"]
  end

  test "user can reclaim own alias" do
    user = User.create(phone: "1777777777", handle: "currnm1", handle_changed_at: 31.days.ago)
    user.handle_aliases.create!(alias: "oldnm01", expires_at: 30.days.from_now)

    post set_handle_url, params: { id: user.id, handle: "oldnm01" }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success

    user.reload
    assert_equal "oldnm01", user.handle
    assert_nil user.handle_aliases.find_by(alias: "oldnm01")
    assert user.handle_aliases.find_by(alias: "currnm1")
  end

  test "get_me returns rename fields" do
    user = User.create(phone: "1888888888", handle: "mehdl01", handle_changed_at: 5.days.ago)
    get get_me_url, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    body = JSON.parse(@response.body)
    assert body["handle_changed_at"].present?
    assert body["next_rename_at"].present?
  end

  test "expired alias does not block rename" do
    user = User.create!(phone: "1999999999", handle: "curhdl1", handle_changed_at: 31.days.ago)
    HandleAlias.create!(user: user, alias: "oldexp1", expires_at: 1.day.ago)

    post set_handle_url, params: { id: user.id, handle: "newexp1" }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success
    assert user.reload.handle_aliases.active.exists?(alias: "curhdl1")
  end

  test "should set image url" do
    user = User.create(phone: "1234567890")
    post set_image_url_url, params: { id: user.id, image_url: "http://example.com/image.png" }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success
    assert JSON.parse(@response.body).key?("result")
  end

  test "should set encrypted keys with proof of key ownership" do
    user = User.create(phone: "1234567890")
    key = EvmTestKey.new
    post set_encrypted_keys_url, params: key.binding_params(user), headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success, @response.body
    user.reload
    assert_equal key.address, user.evm_chain_active_key.downcase
    assert_equal key.safe_address, user.evm_chain_address.downcase
  end

  test "a bound key cannot be replaced" do
    user = User.create(phone: "1234567890")
    auth = { "Authorization" => "Bearer #{user.gen_auth_token}" }
    post set_encrypted_keys_url, params: EvmTestKey.new.binding_params(user), headers: auth
    assert_response :success

    post set_encrypted_keys_url, params: EvmTestKey.new.binding_params(user), headers: auth
    assert_response :bad_request
    assert_equal "key_already_bound", JSON.parse(@response.body)["code"]
  end

  test "binding without proof, or claiming someone else's key or Safe, is refused" do
    victim = EvmTestKey.new
    user = User.create(phone: "1234567890")
    auth = { "Authorization" => "Bearer #{user.gen_auth_token}" }
    mine = EvmTestKey.new

    [
      { id: user.id, encrypted_keys: "x", evm_chain_active_key: victim.address, evm_chain_address: victim.safe_address },
      mine.binding_params(user).merge(evm_chain_active_key: victim.address),
      mine.binding_params(user).merge(evm_chain_address: victim.safe_address),
      # 签名是给别的账户签的
      mine.binding_params(User.create(phone: "1999")).merge(id: user.id)
    ].each do |params|
      post set_encrypted_keys_url, params: params, headers: auth
      assert_response :bad_request
      assert_equal "invalid_key_proof", JSON.parse(@response.body)["code"], params.inspect
    end
    assert_nil user.reload.evm_chain_active_key
  end

  test "one key can be bound to only one account" do
    key = EvmTestKey.new
    first = User.create(phone: "1234567890")
    User.where(id: first.id).update_all(evm_chain_active_key: key.address.upcase.sub("0X", "0x"), evm_chain_address: key.safe_address)

    second = User.create(phone: "1234567891")
    post set_encrypted_keys_url, params: key.binding_params(second), headers: { "Authorization" => "Bearer #{second.gen_auth_token}" }
    assert_response :bad_request
    assert_equal "key_in_use", JSON.parse(@response.body)["code"]
  end

  V2_KEYSTORE = { version: 2, crypto: { ciphertext: "AAAA", iv: "00" * 12, salt: "11" * 16, kdf: "pbkdf2",
                                        cipher: "aes-gcm", iterations: 100_000, hash: "SHA-256", keyShare: true } }.to_json

  def bound_user(key)
    user = User.create!(phone: "13800000050", evm_chain_active_key: key.address, evm_chain_address: key.safe_address,
                        encrypted_keys: '{"version":1,"crypto":{"salt":"aa"}}')
    [ user, { "Authorization" => "Bearer #{user.gen_auth_token}" } ]
  end

  def update_params(user, key, issued_at: Time.current.to_i, encrypted_keys: V2_KEYSTORE, verifier: "ab" * 32, key_share: "cd" * 32)
    message = KeystoreVault.update_message(user.id, issued_at, encrypted_keys, verifier, key_share)
    { encrypted_keys: encrypted_keys, verifier: verifier, key_share: key_share, issued_at: issued_at,
      public_key: key.public_key, signature: key.personal_sign(message) }
  end

  test "binding can create a v2 keystore directly" do
    user = User.create(phone: "1234567890")
    key = EvmTestKey.new
    params = key.binding_params(user).merge(encrypted_keys: V2_KEYSTORE, verifier: "ab" * 32, key_share: "cd" * 32)
    post set_encrypted_keys_url, params: params, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success, @response.body
    assert_equal "cd" * 32, KeystoreVault.unlock!(user.reload, "ab" * 32)
  end

  test "v1 keystores are upgraded with a signature from the bound key" do
    key = EvmTestKey.new
    user, auth = bound_user(key)
    get get_keystore_url, headers: auth
    assert_equal 1, JSON.parse(@response.body)["version"]
    get get_me_url, headers: auth
    assert_equal 1, JSON.parse(@response.body)["keystore_version"]
    assert JSON.parse(@response.body)["encrypted_keys"].present?, "old pages still read v1 from get_me"

    post update_keystore_url, params: update_params(user, key), headers: auth
    assert_response :success, @response.body

    get get_me_url, headers: auth
    body = JSON.parse(@response.body)
    assert_equal 2, body["keystore_version"]
    assert_not body.key?("encrypted_keys")
    get get_encrypted_keys_url, params: { id: user.id }, headers: auth
    assert_equal "keystore_v2", JSON.parse(@response.body)["code"]
    get get_keystore_url, headers: auth
    body = JSON.parse(@response.body)
    assert_equal [ 2, "11" * 16, 100_000 ], [ body["version"], body.dig("params", "salt"), body.dig("params", "iterations") ]
    assert_not body.key?("encrypted_keys")

    post unlock_keystore_url, params: { verifier: "00" * 32 }, headers: auth
    body = JSON.parse(@response.body)
    assert_equal [ "bad_passcode", 9 ], [ body["code"], body["attempts_left"] ]
    post unlock_keystore_url, params: { verifier: "ab" * 32 }, headers: auth
    assert_response :success
    assert_equal [ V2_KEYSTORE, "cd" * 32 ], JSON.parse(@response.body).values_at("encrypted_keys", "key_share")
  end

  test "update_keystore refuses other keys, tampered content, stale and replayed signatures" do
    key = EvmTestKey.new
    user, auth = bound_user(key)
    signed = update_params(user, key)
    [
      update_params(user, EvmTestKey.new),
      signed.merge(key_share: "ee" * 32),
      update_params(user, key, issued_at: 20.minutes.ago.to_i),
      update_params(user, key, encrypted_keys: '{"version":1}')
    ].each do |params|
      post update_keystore_url, params: params, headers: auth
      assert_response :bad_request
      assert_equal "invalid_keystore", JSON.parse(@response.body)["code"], params.inspect
    end
    assert_equal 1, KeystoreVault.version(user.reload)

    post update_keystore_url, params: signed, headers: auth
    assert_response :success
    post update_keystore_url, params: signed, headers: auth
    assert_response :bad_request, "the same signature cannot be replayed"
  end

  test "keystore endpoints need a login" do
    get get_keystore_url
    assert_response :unauthorized
    post unlock_keystore_url, params: { verifier: "ab" * 32 }
    assert_response :unauthorized
  end

  test "should get encrypted keys" do
    user = User.create(phone: "1234567890")
    get get_encrypted_keys_url, params: { id: user.id }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success
    assert JSON.parse(@response.body).key?("result")
    assert JSON.parse(@response.body).key?("encrypted_keys")
  end

  test "set_evm_chain_address is gone" do
    user = User.create(phone: "1234567890")
    post "/set_evm_chain_address", params: { id: user.id, evm_chain_address: "0x1234567890", evm_chain_active_key: "0x1234567890" },
                                   headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :not_found
    assert_nil user.reload.evm_chain_active_key
  end

  test "get_user returns only public fields" do
    user = User.create!(phone: "13800000000", email: "a@example.com", handle: "public-alice")
    get get_user_url, params: { id: user.id }
    assert_response :success
    assert_equal({ "id" => user.id, "handle" => "public-alice", "image_url" => nil, "evm_chain_address" => nil,
                   "evm_chain_active_key" => nil, "can_send_badge" => user.can_send_badge }, JSON.parse(@response.body))
  end

  test "get_by_handle finds by phone only for signed-in users and never returns the phone" do
    target = User.create!(phone: "13800000001", handle: "phone-target", evm_chain_address: "0x" + "ab" * 20)
    get get_by_handle_url, params: { handle: "13800000001" }
    assert_equal "User Not Found", JSON.parse(@response.body)["message"]

    me = User.create!(phone: "13800000002")
    get get_by_handle_url, params: { handle: "13800000001" }, headers: { "Authorization" => "Bearer #{me.gen_auth_token}" }
    assert_response :success
    body = JSON.parse(@response.body)
    assert_equal target.id, body["id"]
    assert_equal "0x" + "ab" * 20, body["evm_chain_address"]
    assert_not body.key?("phone")

    get get_by_handle_url, params: { handle: "phone-target" }
    assert_equal target.id, JSON.parse(@response.body)["id"]
    assert_not JSON.parse(@response.body).key?("phone")
  end

  test "should get me" do
    user = User.create(phone: "1234567890")
    get get_me_url, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success
    assert JSON.parse(@response.body).key?("id")
    assert JSON.parse(@response.body).key?("handle")
    assert JSON.parse(@response.body).key?("email")
    assert JSON.parse(@response.body).key?("phone")
    assert JSON.parse(@response.body).key?("image_url")
    assert JSON.parse(@response.body).key?("evm_chain_address")
    assert JSON.parse(@response.body).key?("evm_chain_active_key")
    assert JSON.parse(@response.body).key?("remaining_gas_credits")
  end

  SAFE_ADDR = "0x" + "5a" * 20
  RECEIVER_ADDR = "0x" + "7c" * 20

  # 链上回执：SAFE_ADDR 的 UserOp，实际 gas 为 gas
  def with_chain_receipt(gas: 4321, success: true, &block)
    word = ->(n) { n.to_s(16).rjust(64, "0") }
    event = { "topics" => [ UserOpReceipt::EVENT_TOPIC, "0x" + "ab" * 32, "0x" + "0" * 24 + SAFE_ADDR.delete_prefix("0x"), "0x" + "0" * 64 ],
              "data" => "0x" + word.(0) + word.(success ? 1 : 0) + word.(gas) + word.(1) }
    ChainRpc.stub(:get_transaction_receipt, { "status" => "0x1", "logs" => [ event ] }) do
      ChainRpc.stub(:get_transaction, { "input" => "0x" + RECEIVER_ADDR.delete_prefix("0x") }, &block)
    end
  end

  def tx_params(**over)
    { tx_hash: "0x" + "12" * 32, gas_used: 100, status: "success", chain: "op mainnet", data: "data", memo: "test memo",
      sender_note: "s note", receiver_note: "r note", sender_address: SAFE_ADDR, receiver_address: RECEIVER_ADDR }.merge(over)
  end

  test "should add transaction" do
    user = User.create(phone: "1234567890", evm_chain_address: SAFE_ADDR)
    with_chain_receipt do
      post add_transaction_url, params: tx_params, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    end
    assert_response :success, @response.body
    assert JSON.parse(@response.body).key?("result")

    tx = Transaction.find_by(tx_hash: "0x" + "12" * 32)
    assert_equal "test memo", tx.memo
    assert_equal "s note", tx.sender_note
    assert_equal "r note", tx.receiver_note
    assert_equal SAFE_ADDR, tx.sender_address
    assert_equal RECEIVER_ADDR, tx.receiver_address

    get get_transactions_url, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success
    assert JSON.parse(@response.body).key?("transactions")

    get remaining_free_transactions_url, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success
    assert JSON.parse(@response.body).key?("remaining_free_transactions")
  end

  test "transaction records must match the chain" do
    user = User.create!(phone: "13800000031", evm_chain_address: SAFE_ADDR)
    victim = User.create!(phone: "13800000032", evm_chain_address: "0x" + "6b" * 20)
    headers = { "Authorization" => "Bearer #{user.gen_auth_token}" }
    before = Transaction.count

    # 冒充别人发出的交易
    with_chain_receipt { post add_transaction_url, params: tx_params(sender_address: victim.evm_chain_address), headers: headers }
    assert_equal "invalid_transaction", JSON.parse(@response.body)["code"]

    # 写一条收款方与链上无关的记录
    with_chain_receipt { post add_transaction_url, params: tx_params(receiver_address: victim.evm_chain_address), headers: headers }
    assert_equal "invalid_transaction", JSON.parse(@response.body)["code"]
    assert_equal before, Transaction.count
  end

  test "gas and status come from the receipt, never from the client" do
    user = User.create!(phone: "13800000033", evm_chain_address: SAFE_ADDR)
    with_chain_receipt(gas: 5000, success: false) do
      post add_transaction_with_gas_credits_url, params: tx_params(gas_used: -1_000_000, status: "success"),
                                                 headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    end
    assert_response :success, @response.body
    tx = Transaction.last
    assert_equal 5000, tx.gas_used
    assert_equal "failed", tx.status
    assert_equal 5000, user.reload.total_used_gas_credits
  end

  test "should signin with email" do
    post send_email_url, params: { email: "delivered@resend.dev" }
    assert_response :success
    assert_equal({ "result" => "ok", "email" => "delivered@resend.dev" }, JSON.parse(@response.body))
    code = ActionMailer::Base.deliveries.last.body.encoded[/\d{6}/]

    post signin_with_email_url, params: { email: "delivered@resend.dev", code: code }
    assert_response :success
    assert_equal "delivered@resend.dev", JSON.parse(@response.body)["email"]

    # 用过的码不能再用
    post signin_with_email_url, params: { email: "delivered@resend.dev", code: code }
    assert_equal "invalid_code", JSON.parse(@response.body)["code"]
  end

  test "send email rejects a malformed address" do
    post send_email_url, params: { email: "not-an-email" }
    assert_equal "invalid_email", JSON.parse(@response.body)["code"]
  end

  test "should add transaction with gas credits" do
    user = User.create(phone: "1234567890", evm_chain_address: SAFE_ADDR)
    with_chain_receipt do
      post add_transaction_with_gas_credits_url, params: tx_params.except(:memo), headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    end
    assert_response :success, @response.body
    assert JSON.parse(@response.body).key?("result")

    tx = Transaction.find_by(tx_hash: "0x" + "12" * 32)
    assert_equal "s note", tx.sender_note
    assert_equal "r note", tx.receiver_note
    assert_equal SAFE_ADDR, tx.sender_address
    assert_equal RECEIVER_ADDR, tx.receiver_address
  end

  test "should set transaction note as owner" do
    user = User.create(phone: "1234567890")
    tx = Transaction.create(user: user, tx_hash: "0xowner", status: "success")
    post set_transaction_note_url, params: { id: tx.id, sender_note: "owner note" }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success
    assert_equal "owner note", tx.reload.sender_note
  end

  test "should set transaction note as sender" do
    user = User.create(phone: "1234567890", evm_chain_address: "0xsender")
    other_user = User.create(phone: "0987654321")
    tx = Transaction.create(user: other_user, tx_hash: "0xsender_tx", sender_address: "0xsender")
    post set_transaction_note_url, params: { id: tx.id, sender_note: "sender note" }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success
    assert_equal "sender note", tx.reload.sender_note
  end

  test "should set transaction note as receiver" do
    user = User.create(phone: "1234567890", evm_chain_address: "0xreceiver")
    other_user = User.create(phone: "0987654321")
    tx = Transaction.create(user: other_user, tx_hash: "0xreceiver_tx", receiver_address: "0xreceiver")
    post set_transaction_note_url, params: { id: tx.id, receiver_note: "receiver note" }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success
    assert_equal "receiver note", tx.reload.receiver_note
  end

  test "should fail set transaction note if unauthorized" do
    user = User.create(phone: "1234567890")
    other_user = User.create(phone: "0987654321")
    tx = Transaction.create(user: other_user, tx_hash: "0xunauthorized", sender_address: "0xsomeone", receiver_address: "0xelse")
    post set_transaction_note_url, params: { id: tx.id, sender_note: "hacker note" }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :bad_request
  end

  test "should get transactions with txhashes filter" do
    user = User.create(phone: "1234567890")
    tx1 = Transaction.create(user: user, tx_hash: "0x1", status: "success")
    tx2 = Transaction.create(user: user, tx_hash: "0x2", status: "success")
    tx3 = Transaction.create(user: user, tx_hash: "0x3", status: "success")

    get get_transactions_url, params: { txhashes: "0x1,0x3" }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success
    txs = JSON.parse(@response.body)["transactions"]
    assert_equal 2, txs.length
    hashes = txs.map { |t| t["tx_hash"] }
    assert_includes hashes, "0x1"
    assert_includes hashes, "0x3"
    assert_not_includes hashes, "0x2"
  end

  test "should get token classes" do
    user = User.create(phone: "1234567890")
    post add_token_class_url, params: { token_type: "ERC20", chain: "ethereum", chain_id: 1, address: "0x1234567890", name: "Test Token", symbol: "TT", decimals: 18, image_url: "http://example.com/image.png", publisher: "Test Publisher", publisher_address: "0x1234567890", position: 0, description: "Test Description" }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success
    assert JSON.parse(@response.body).key?("result")
    assert TokenClass.find_by(address: "0x1234567890").decimals == 18
    assert TokenClass.find_by(address: "0x1234567890").chain_id == 1

    get get_token_classes_url
    assert_response :success
    assert JSON.parse(@response.body).key?("result")
    assert JSON.parse(@response.body).key?("token_classes")
  end

  test "user-added tokens are visible only to their publisher until an admin lists them" do
    publisher = User.create!(phone: "13800000040")
    other = User.create!(phone: "13800000041")
    admin = User.create!(phone: "13800000042")
    post add_token_class_url, params: { token_type: "ERC20", chain: "optimism", chain_id: 10, address: "0x" + "0b" * 20, name: "USD Coin", symbol: "USDC", decimals: 6 },
                              headers: { "Authorization" => "Bearer #{publisher.gen_auth_token}" }
    fake = TokenClass.find_by(symbol: "USDC")
    assert_not fake.listed

    symbols = ->(user = nil) {
      get get_token_classes_url, headers: user ? { "Authorization" => "Bearer #{user.gen_auth_token}" } : {}
      JSON.parse(@response.body)["token_classes"].map { |t| t["symbol"] }
    }
    assert_includes symbols.(publisher), "USDC"
    assert_not_includes symbols.(other), "USDC"
    assert_not_includes symbols.(), "USDC"

    post "/set_token_class_listed", params: { id: fake.id, listed: true }, headers: { "Authorization" => "Bearer #{other.gen_auth_token}" }
    assert_equal "forbidden", JSON.parse(@response.body)["code"]

    ENV["ADMIN_USER_IDS"] = admin.id
    post "/set_token_class_listed", params: { id: fake.id, listed: true }, headers: { "Authorization" => "Bearer #{admin.gen_auth_token}" }
    assert_response :success
    assert_includes symbols.(other), "USDC"
  ensure
    ENV.delete("ADMIN_USER_IDS")
  end

  test "add_wallet refuses multisig rows" do
    user = User.create!(phone: "13800000043")
    post add_wallet_url, params: { name: "x", wallet_type: "multisig", evm_chain_address: "0x" + "0c" * 20 }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :bad_request
    assert_equal 0, Wallet.where(wallet_type: "multisig", user_id: user.id).count
  end

  test "should add wallet" do
    user = User.create(phone: "1234567890")
    post add_wallet_url, params: { name: "Test Wallet", wallet_type: "evm", chain: "ethereum", evm_chain_address: "0x1234567890", evm_chain_active_key: "0x1234567890", encrypted_keys: "encrypted_data", format: "json" }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success
    assert JSON.parse(@response.body).key?("result")
    assert JSON.parse(@response.body).key?("wallet")

    get get_wallets_url, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert JSON.parse(@response.body).key?("result")
    assert JSON.parse(@response.body).key?("wallets")

    assert JSON.parse(@response.body)["wallets"].first["id"] == Wallet.find_by(name: "Test Wallet").id
    assert JSON.parse(@response.body)["wallets"].first["name"] == "Test Wallet"
    assert JSON.parse(@response.body)["wallets"].first["wallet_type"] == "evm"

    post remove_wallet_url, params: { id: Wallet.find_by(name: "Test Wallet").id }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success
    assert JSON.parse(@response.body).key?("result")

    get get_wallets_url, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success
  end

  test "should set and get contacts" do
    user = User.create(phone: "1234567890")
    contact_list = [ { "name" => "Alice", "phone" => "9876543210" }, { "name" => "Bob", "phone" => "5555555555" } ]

    post set_contacts_url, params: { id: user.id, contact_list: contact_list }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success
    assert_equal "ok", JSON.parse(@response.body)["result"]

    user.reload
    assert_equal contact_list, user.contact_list

    get get_contacts_url, params: { id: user.id }
    assert_equal "Invalid Auth Token", JSON.parse(@response.body)["message"]

    get get_contacts_url, params: { id: user.id }, headers: { "Authorization" => "Bearer #{user.gen_auth_token}" }
    assert_response :success
    assert_equal "ok", JSON.parse(@response.body)["result"]
    assert_equal contact_list, JSON.parse(@response.body)["contacts"]
  end

  test "should fail set_contacts without auth" do
    user = User.create(phone: "1234567890")
    other_user = User.create(phone: "9999999999")
    contact_list = [ { "name" => "Alice", "phone" => "9876543210" } ]

    post set_contacts_url, params: { id: user.id, contact_list: contact_list }, headers: { "Authorization" => "Bearer #{other_user.gen_auth_token}" }
    assert_response :bad_request
    assert_equal "Invalid Auth Token", JSON.parse(@response.body)["message"]
  end

  test "should fail get_contacts for non-existent user" do
    get get_contacts_url, params: { id: "nonexistent" }
    assert_response :bad_request
    assert_equal "User Not Found", JSON.parse(@response.body)["message"]
  end

  # ── 登出与 token 生命周期 ────────────────────────────────────────────────
  #
  # 改动之前根本没有 logout 端点：前端「退出」只是删掉本地 cookie，服务端那条
  # 记录还在、还有效。

  test "logout 吊销当前 token" do
    user = User.create(phone: "13900000002")
    token = user.gen_auth_token
    headers = { "Authorization" => "Bearer #{token}" }

    get get_me_url, headers: headers
    assert_response :success

    post logout_url, headers: headers
    assert_response :success

    get get_me_url, headers: headers
    assert_equal "User Not Found", JSON.parse(@response.body)["message"]
  end

  test "logout 不影响该用户的其他设备" do
    user = User.create(phone: "13900000003")
    phone_token = user.gen_auth_token
    laptop_token = user.gen_auth_token

    post logout_url, headers: { "Authorization" => "Bearer #{phone_token}" }
    assert_response :success

    get get_me_url, headers: { "Authorization" => "Bearer #{laptop_token}" }
    assert_response :success
  end

  test "logout_all 吊销全部 token" do
    user = User.create(phone: "13900000004")
    phone_token = user.gen_auth_token
    laptop_token = user.gen_auth_token

    post logout_all_url, headers: { "Authorization" => "Bearer #{phone_token}" }
    assert_response :success
    assert_equal 2, JSON.parse(@response.body)["revoked"]

    get get_me_url, headers: { "Authorization" => "Bearer #{laptop_token}" }
    assert_equal "User Not Found", JSON.parse(@response.body)["message"]
  end

  test "过期的 token 认证失败" do
    user = User.create(phone: "13900000005")
    token = user.gen_auth_token
    AuthToken.find_by(token: token).update_column(:expires_at, 1.minute.ago)

    get get_me_url, headers: { "Authorization" => "Bearer #{token}" }
    assert_equal "User Not Found", JSON.parse(@response.body)["message"]
  end

  test "认证成功时记录 last_used_at" do
    user = User.create(phone: "13900000006")
    token = user.gen_auth_token

    get get_me_url, headers: { "Authorization" => "Bearer #{token}" }
    assert_response :success
    assert AuthToken.find_by(token: token).last_used_at.present?
  end
end
