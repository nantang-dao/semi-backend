require "test_helper"
require "minitest/mock"

class MultisigControllerTest < ActionDispatch::IntegrationTest
  # 后端会验签，ALICE / BOB 要有真私钥（Hardhat 测试账户 #2、#1）。保持 ALICE < BOB < CAROL
  ALICE_KEY = EvmTestKey.new("0x5de4111afa1a4b94908f83103eb1f1706367c2e68ca870fc3fb9a804cdab365a")
  BOB_KEY = EvmTestKey.new("0x59c6995e998f97a5a0044966f0945389dc9e86dae88c7a8412f4603b6b78690d")
  ALICE = ALICE_KEY.address
  BOB = BOB_KEY.address
  CAROL = "0xcccccccccccccccccccccccccccccccccccccccc"
  SAFE = "0x53d961df57ccd0da6e6d6eae3377d4ea5b3f273d"

  ADD_CAROL = { new_owner: CAROL, new_threshold: 2 }.freeze
  REMOVE_BOB = { owner: BOB, prev_owner: ALICE, new_threshold: 1 }.freeze
  THRESHOLD_1 = { new_threshold: 1 }.freeze

  # 按 call_detail 编码的真实 calldata（后端要求两者一致，编码本身由 multisig_intent_test 锁住）
  def call_data(tx_type, detail)
    "0x" + MultisigIntent.config_call_data(tx_type, detail.with_indifferent_access)
  end

  setup do
    @alice = User.create!(evm_chain_active_key: ALICE, handle: "alice-#{SecureRandom.hex(3)}")
    @bob = User.create!(evm_chain_active_key: BOB, handle: "bob-#{SecureRandom.hex(3)}")
    @alice_token = AuthToken.create!(user: @alice).token
    @bob_token = AuthToken.create!(user: @bob).token
  end

  def auth(token = @alice_token)
    { "Authorization" => "Bearer #{token}" }
  end

  def body
    JSON.parse(@response.body)
  end

  def create_wallet(chain_ids: [ 10, 42161, 1 ], owners: [ ALICE, BOB ], threshold: 2)
    post "/create_multisig_wallet", params: {
      name: "Team", chain_id: chain_ids.first, chain_ids: chain_ids,
      owners: owners.map { |a| { address: a } }, threshold: threshold, safe_address: SAFE
    }, headers: auth, as: :json
    assert_response :success, @response.body
    body["wallets"]
  end

  test "creates one wallet row per chain with the same owners and initial config" do
    wallets = create_wallet
    assert_equal [ 10, 42161, 1 ], wallets.map { |w| w["chain_id"] }
    wallets.each do |w|
      assert_equal SAFE, w["safe_address"]
      assert_equal [ ALICE, BOB ], w["initial_owners"]
      assert_equal 2, w["initial_threshold"]
    end

    get "/get_multisig_wallets", headers: auth(@bob_token)
    assert_equal 3, body["wallets"].length
  end

  test "wallet owners are visible to members of the Safe on any chain, without phone numbers" do
    @alice.update!(phone: "13800000010")
    wallets = create_wallet(chain_ids: [ 10, 42161 ])
    arb = Wallet.find(wallets.last["id"])
    arb.wallet_owners.where(owner_address: BOB).destroy_all # Bob 在 Arbitrum 上已被移除

    get "/get_multisig_wallet_owners", params: { wallet_id: arb.id }, headers: auth(@bob_token)
    assert_response :success, @response.body
    assert_equal [ ALICE ], body["owners"].map { |o| o["owner_address"] }
    assert_not body["owners"].first.key?("phone")

    carol = User.create!(evm_chain_active_key: CAROL, handle: "carol-#{SecureRandom.hex(3)}")
    get "/get_multisig_wallet_owners", params: { wallet_id: arb.id }, headers: auth(AuthToken.create!(user: carol).token)
    assert_equal "You are not an owner of this wallet", body["message"]
  end

  test "owner names come from handles, not from the proposal or phone numbers" do
    @bob.update!(phone: "13800000011", handle: nil)
    wallets = create_wallet(chain_ids: [ 10 ])
    detail = REMOVE_BOB.merge(owner_name: "Trusted Alice")
    post "/propose_multisig_tx", params: {
      wallet_id: wallets.first["id"], tx_type: "remove_owner", call_detail: detail, evm_call_data: call_data("remove_owner", REMOVE_BOB)
    }, headers: auth, as: :json
    assert_response :success, @response.body
    assert_not body["tx"]["call_detail"].key?("owner_name")
    assert_not MultisigTransaction.find(body["tx"]["id"]).call_detail.key?("owner_name")
    assert_equal @alice.handle, body["tx"]["proposer"]["name"]

    @bob.update!(handle: "bob-renamed")
    get "/get_multisig_tx", params: { id: body["tx"]["id"] }, headers: auth
    assert_equal "bob-renamed", body["tx"]["call_detail"]["owner_name"]
    assert_not @response.body.include?("13800000011")
  end

  test "stored owner snapshots with phone names are cleaned on read" do
    wallets = create_wallet(chain_ids: [ 10 ])
    tx = MultisigTransaction.create!(
      wallet_id: wallets.first["id"], proposer: @alice, chain_id: 10, tx_type: "change_threshold",
      call_detail: THRESHOLD_1.merge(new_owner_name: "13800000012"), evm_call_data: call_data("change_threshold", THRESHOLD_1),
      threshold_at_creation: 2, status: "executed", expires_at: 5.days.from_now,
      owner_snapshot: { owners: [ { address: BOB, name: "13800000012", signed: true } ], proposer: { id: @alice.id, name: "13800000012" } }
    )
    get "/get_multisig_tx", params: { id: tx.id }, headers: auth
    assert_response :success, @response.body
    assert_not @response.body.include?("13800000012")
    assert_equal @bob.handle, body["tx"]["owner_snapshot"]["owners"].first["name"]
  end

  test "rejects mixing mainnet and testnet chains" do
    post "/create_multisig_wallet", params: {
      name: "Team", chain_id: 10, chain_ids: [ 10, 11155111 ],
      owners: [ { address: ALICE }, { address: BOB } ], threshold: 1, safe_address: SAFE
    }, headers: auth, as: :json
    assert_response :bad_request
  end

  test "same address cannot be registered twice on a chain" do
    create_wallet(chain_ids: [ 10 ])
    post "/create_multisig_wallet", params: {
      name: "Again", chain_id: 10, owners: [ { address: ALICE }, { address: BOB } ], threshold: 1, safe_address: SAFE
    }, headers: auth, as: :json
    assert_response :bad_request
    assert_equal "Wallet already exists", body["message"]
  end

  test "legacy rows with mixed-case addresses are matched without being rewritten" do
    mixed = "0x53D961df57ccd0da6e6d6eae3377d4ea5b3f273D"
    legacy = Wallet.create!(user_id: @alice.id, name: "Old", wallet_type: "multisig", chain: "10", chain_id: 10,
                            evm_chain_address: mixed, threshold: 2, initial_owners: [ ALICE, BOB ], initial_threshold: 2)
    [ ALICE, BOB ].each_with_index { |a, i| WalletOwner.create!(wallet: legacy, owner_address: a, position: i) }

    post "/create_multisig_wallet", params: {
      name: "Dup", chain_id: 10, owners: [ { address: ALICE }, { address: BOB } ], threshold: 2, safe_address: SAFE
    }, headers: auth, as: :json
    assert_equal "Wallet already exists", body["message"]

    post "/add_multisig_wallet_chains", params: { wallet_id: legacy.id, chain_ids: [ 42161 ] }, headers: auth, as: :json
    assert_response :success, @response.body
    assert_equal mixed, legacy.reload.evm_chain_address
    assert_equal [ legacy.id ], Wallet.find(body["wallets"].first["id"]).multisig_siblings.pluck(:id)
  end

  test "add_multisig_wallet_chains enables other chains with the initial config" do
    wallets = create_wallet(chain_ids: [ 10 ])
    op = Wallet.find(wallets.first["id"])

    # 任一 owner 都可以启用
    post "/add_multisig_wallet_chains", params: { wallet_id: op.id, chain_ids: [ 42161, 10 ] }, headers: auth(@bob_token), as: :json
    assert_response :success, @response.body
    created = body["wallets"]
    assert_equal [ 42161 ], created.map { |w| w["chain_id"] }

    arb = Wallet.find(created.first["id"])
    assert_equal [ ALICE, BOB ], arb.owner_address_list.sort
    assert_equal 2, arb.threshold
  end

  test "add_multisig_wallet_chains is refused once members or threshold changed" do
    wallets = create_wallet(chain_ids: [ 10 ])
    op = Wallet.find(wallets.first["id"])
    # OP 上已经加了 Carol、门限改成 1（新链上生效的会是旧成员）
    WalletOwner.create!(wallet: op, owner_address: CAROL, position: 2)
    op.update!(threshold: 1)

    post "/add_multisig_wallet_chains", params: { wallet_id: op.id, chain_ids: [ 42161 ] }, headers: auth, as: :json
    assert_response :bad_request
    assert_equal "config_changed", body["code"]
    assert_equal 1, Wallet.multisig_at(SAFE).count
  end

  test "add_multisig_wallet_chains is refused while a member change is pending" do
    wallets = create_wallet(chain_ids: [ 10 ])
    post "/propose_multisig_tx", params: {
      wallet_id: wallets.first["id"], tx_type: "change_threshold",
      call_detail: THRESHOLD_1, evm_call_data: call_data("change_threshold", THRESHOLD_1)
    }, headers: auth, as: :json
    assert_response :success, @response.body

    post "/add_multisig_wallet_chains", params: { wallet_id: wallets.first["id"], chain_ids: [ 1 ] }, headers: auth, as: :json
    assert_response :bad_request
    assert_equal "config_change_pending", body["code"]
  end

  test "owner change on one chain is refused while other chains apply" do
    wallets = create_wallet
    post "/propose_multisig_tx", params: {
      wallet_id: wallets.first["id"], tx_type: "add_owner",
      call_detail: ADD_CAROL, evm_call_data: call_data("add_owner", ADD_CAROL)
    }, headers: auth, as: :json
    assert_response :bad_request
    assert_equal "group_required", body["code"]
    assert_equal [ 42161, 1 ], body["chain_ids"].sort.reverse
  end

  test "group proposal creates one queued tx per chain sharing a group_id" do
    wallets = create_wallet
    post "/propose_multisig_tx_group", params: {
      txs: wallets.map { |w| { wallet_id: w["id"], tx_type: "add_owner", call_detail: ADD_CAROL, evm_call_data: call_data("add_owner", ADD_CAROL) } }
    }, headers: auth, as: :json
    assert_response :success, @response.body

    txs = body["txs"]
    assert_equal 3, txs.length
    assert_equal 1, txs.map { |t| t["group_id"] }.uniq.length
    assert_equal [ 1, 10, 42161 ], txs.first["group_txs"].map { |g| g["chain_id"] }
    assert txs.all? { |t| t["status"] == "queued" && t["queue_position"] == 1 }

    # 同一变更已在进行，不能再发一次
    post "/propose_multisig_tx_group", params: {
      txs: wallets.map { |w| { wallet_id: w["id"], tx_type: "add_owner", call_detail: ADD_CAROL, evm_call_data: call_data("add_owner", ADD_CAROL) } }
    }, headers: auth, as: :json
    assert_response :bad_request
    assert_equal "change_already_pending", body["code"]
  end

  test "group proposal must cover every applicable chain" do
    wallets = create_wallet
    post "/propose_multisig_tx_group", params: {
      txs: wallets.first(2).map { |w| { wallet_id: w["id"], tx_type: "change_threshold", call_detail: THRESHOLD_1, evm_call_data: call_data("change_threshold", THRESHOLD_1) } }
    }, headers: auth, as: :json
    assert_response :bad_request
    assert_equal "group_required", body["code"]
    assert_equal [ 1 ], body["chain_ids"]
  end

  test "chains where the change no longer applies are not required" do
    wallets = create_wallet
    # 主网上 Carol 已经是 owner（例如之前单独执行过）
    WalletOwner.create!(wallet_id: wallets.last["id"], owner_address: CAROL, position: 2)

    post "/propose_multisig_tx_group", params: {
      txs: wallets.first(2).map { |w| { wallet_id: w["id"], tx_type: "add_owner", call_detail: ADD_CAROL, evm_call_data: call_data("add_owner", ADD_CAROL) } }
    }, headers: auth, as: :json
    assert_response :success, @response.body

    post "/propose_multisig_tx_group", params: {
      txs: [ { wallet_id: wallets.last["id"], tx_type: "add_owner", call_detail: ADD_CAROL, evm_call_data: call_data("add_owner", ADD_CAROL) } ]
    }, headers: auth, as: :json
    assert_response :bad_request
  end

  test "group rejects different changes per chain" do
    wallets = create_wallet
    post "/propose_multisig_tx_group", params: {
      txs: wallets.each_with_index.map { |w, i| { wallet_id: w["id"], tx_type: "change_threshold", call_detail: { new_threshold: i.zero? ? 1 : 2 }, evm_call_data: call_data("change_threshold", { new_threshold: i.zero? ? 1 : 2 }) } }
    }, headers: auth, as: :json
    assert_response :bad_request
  end

  test "withdrawing one tx withdraws unsigned siblings in its group" do
    wallets = create_wallet
    post "/propose_multisig_tx_group", params: {
      txs: wallets.map { |w| { wallet_id: w["id"], tx_type: "remove_owner", call_detail: REMOVE_BOB, evm_call_data: call_data("remove_owner", REMOVE_BOB) } }
    }, headers: auth, as: :json
    assert_response :success, @response.body
    txs = body["txs"]

    signed = MultisigTransaction.find(txs[1]["id"])
    signed.update!(status: "signing", nonce: "0")
    MultisigSignature.create!(multisig_transaction_id: signed.id, signer_address: BOB, signature: "0xsig")

    post "/withdraw_multisig_tx", params: { multisig_tx_id: txs[0]["id"] }, headers: auth, as: :json
    assert_response :success, @response.body
    assert_equal [ txs[0]["id"], txs[2]["id"] ].sort, body["withdrawn_tx_ids"].sort
    assert_equal "signing", signed.reload.status
  end

  test "non-config transactions stay single-chain" do
    wallets = create_wallet
    post "/propose_multisig_tx", params: {
      wallet_id: wallets.first["id"], tx_type: "transfer",
      call_detail: { to: CAROL, amount: "0.1" }, evm_call_data: "0x"
    }, headers: auth, as: :json
    assert_response :success, @response.body
    assert_nil body["tx"]["group_id"]
    assert_equal 10, body["tx"]["chain_id"]
  end
  def snapshot_for(to, value, data = "", nonce: "0", sender: SAFE, chain_id: 10, max_fee: "1000000")
    {
      sender: sender, chainId: chain_id, nonce: nonce, callData: "0x" + MultisigIntent.encode_safe_call_data(to, value, data),
      callGasLimit: "100000", verificationGasLimit: "200000", preVerificationGas: "50000",
      maxFeePerGas: max_fee, maxPriorityFeePerGas: "1000000", validAfter: 0, validUntil: 0,
      initCode: "0x", paymasterAndData: "0x"
    }
  end

  def sign(key, snapshot) = key.sign_digest(SafeOp.safe_op_hash(snapshot))

  test "first signer's snapshot must execute exactly the proposed transaction" do
    wallets = create_wallet(chain_ids: [ 10 ])
    post "/propose_multisig_tx", params: {
      wallet_id: wallets.first["id"], tx_type: "transfer", call_detail: { to: CAROL, amount: "0.01" }, evm_call_data: "0x"
    }, headers: auth, as: :json
    tx_id = body["tx"]["id"]

    # 展示「转 0.01 给 Carol」，快照却是「转 100 给 Bob」
    [
      snapshot_for(BOB, 100 * 10**18),
      snapshot_for(CAROL, 10**16, sender: BOB),
      snapshot_for(CAROL, 10**16, chain_id: 42161),
      snapshot_for(CAROL, 10**16, nonce: "1")
    ].each do |forged|
      post "/submit_multisig_signature", params: {
        multisig_tx_id: tx_id, signer_address: ALICE, signature: "0xsig", nonce: "0", user_op_snapshot: forged
      }, headers: auth, as: :json
      assert_response :bad_request
      assert_equal "intent_mismatch", body["code"], forged.inspect
    end
    assert_equal "queued", MultisigTransaction.find(tx_id).status

    snapshot = snapshot_for(CAROL, 10**16)
    post "/submit_multisig_signature", params: {
      multisig_tx_id: tx_id, signer_address: ALICE, signature: sign(ALICE_KEY, snapshot), nonce: "0", user_op_snapshot: snapshot
    }, headers: auth, as: :json
    assert_response :success, @response.body
    assert_equal "signing", body["tx"]["status"]
  end

  def proposed_transfer
    wallets = create_wallet(chain_ids: [ 10 ])
    post "/propose_multisig_tx", params: {
      wallet_id: wallets.first["id"], tx_type: "transfer", call_detail: { to: CAROL, amount: "0.01" }, evm_call_data: "0x"
    }, headers: auth, as: :json
    body["tx"]["id"]
  end

  test "signatures must recover to the signer over the stored snapshot" do
    tx_id = proposed_transfer
    snapshot = snapshot_for(CAROL, 10**16)

    # 签名人和签的内容都对，但不是本人签的
    post "/submit_multisig_signature", params: {
      multisig_tx_id: tx_id, signer_address: ALICE, signature: sign(BOB_KEY, snapshot), nonce: "0", user_op_snapshot: snapshot
    }, headers: auth, as: :json
    assert_equal "invalid_signature", body["code"]
    assert_equal "queued", MultisigTransaction.find(tx_id).status

    post "/submit_multisig_signature", params: {
      multisig_tx_id: tx_id, signer_address: ALICE, signature: sign(ALICE_KEY, snapshot), nonce: "0", user_op_snapshot: snapshot
    }, headers: auth, as: :json
    assert_response :success, @response.body

    # 生产上出现过的竞态：Bob 在 Alice 上传快照前打开页面，自己建了一份（gas 价不同）来签
    own = snapshot_for(CAROL, 10**16, max_fee: "2000000")
    post "/submit_multisig_signature", params: {
      multisig_tx_id: tx_id, signer_address: BOB, signature: sign(BOB_KEY, own), nonce: "0", user_op_snapshot: own
    }, headers: auth(@bob_token), as: :json
    assert_equal "invalid_signature", body["code"]
    assert_equal 1, MultisigSignature.where(multisig_transaction_id: tx_id).count

    post "/submit_multisig_signature", params: {
      multisig_tx_id: tx_id, signer_address: BOB, signature: sign(BOB_KEY, snapshot)
    }, headers: auth(@bob_token), as: :json
    assert_response :success, @response.body
    assert_equal "ready", body["tx"]["status"]
  end

  test "a snapshot whose recorded safeOpHash disagrees with its contents is refused" do
    tx_id = proposed_transfer
    snapshot = snapshot_for(CAROL, 10**16).merge(safeOpHash: "0x" + "ab" * 32)
    post "/submit_multisig_signature", params: {
      multisig_tx_id: tx_id, signer_address: ALICE, signature: sign(ALICE_KEY, snapshot), nonce: "0", user_op_snapshot: snapshot
    }, headers: auth, as: :json
    assert_equal "intent_mismatch", body["code"]
  end

  def user_op_event(user_op_hash, success: true)
    word = ->(n) { n.to_s(16).rjust(64, "0") }
    {
      "address" => SafeOp::ENTRY_POINT,
      "topics" => [ UserOpReceipt::EVENT_TOPIC, user_op_hash, "0x" + "0" * 24 + SAFE.delete_prefix("0x"), "0x" + "0" * 64 ],
      "data" => "0x" + word.(0) + word.(success ? 1 : 0) + word.(1234) + word.(99)
    }
  end

  def receipt(*logs) = { "status" => "0x1", "to" => SafeOp::ENTRY_POINT, "logs" => logs }

  test "confirm requires the receipt of this transaction's own UserOp" do
    wallets = create_wallet(chain_ids: [ 10 ])
    wallet = Wallet.find(wallets.first["id"])
    snapshot = snapshot_for(SAFE, 0, call_data("change_threshold", THRESHOLD_1).delete_prefix("0x"), nonce: "7")
    tx = MultisigTransaction.create!(
      wallet: wallet, proposer: @alice, chain_id: 10, queue_position: 1, tx_type: "change_threshold", nonce: "7",
      call_detail: THRESHOLD_1, evm_call_data: call_data("change_threshold", THRESHOLD_1), threshold_at_creation: 2,
      status: "executing", executor_id: @alice.id, user_op_snapshot: snapshot, expires_at: 5.days.from_now
    )
    confirm = ->(rcpt, **extra) {
      ChainRpc.stub(:get_transaction_receipt, rcpt) do
        post "/confirm_multisig_tx", params: { multisig_tx_id: tx.id, tx_hash: "0x" + "12" * 32, **extra }, headers: auth, as: :json
      end
    }

    # 同一 Safe 另一笔（比如以前的）成功 UserOp 的回执，前端还声称就是它
    old_hash = "0x" + "ee" * 32
    confirm.call(receipt(user_op_event(old_hash)), user_op_hash: old_hash)
    assert_response :bad_request
    assert_match(/找不到这笔交易的 UserOp/, body["message"])
    assert_equal "executing", tx.reload.status
    assert_equal 2, wallet.reload.threshold

    confirm.call(receipt(user_op_event(SafeOp.user_op_hash(snapshot), success: false)))
    assert_match(/内层调用回滚/, body["message"])
    assert_equal "executing", tx.reload.status

    confirm.call(receipt(user_op_event(old_hash), user_op_event(SafeOp.user_op_hash(snapshot))))
    assert_response :success, @response.body
    assert_equal "executed", tx.reload.status
    assert_equal 1, wallet.reload.threshold
  end

  test "rejection snapshot must be an empty self-call at the target nonce" do
    wallets = create_wallet(chain_ids: [ 10 ])
    wallet = Wallet.find(wallets.first["id"])
    target = MultisigTransaction.create!(
      wallet: wallet, proposer: @alice, chain_id: 10, queue_position: 1, tx_type: "transfer", nonce: "3",
      call_detail: { to: CAROL, amount: "0.01" }, evm_call_data: "0x", threshold_at_creation: 2,
      status: "signing", expires_at: 5.days.from_now
    )
    MultisigSignature.create!(multisig_transaction_id: target.id, signer_address: ALICE, signature: "0xsig")

    propose = ->(snapshot) {
      post "/propose_multisig_tx", params: {
        wallet_id: wallet.id, tx_type: "cancel", call_detail: { reason: "x" }, evm_call_data: "0x",
        replaces_tx_id: target.id, user_op_snapshot: snapshot
      }, headers: auth(@bob_token), as: :json
    }

    propose.call(snapshot_for(BOB, 100 * 10**18, nonce: "3"))
    assert_response :bad_request
    assert_equal "intent_mismatch", body["code"]

    propose.call(snapshot_for(SAFE, 0, nonce: "3"))
    assert_response :success, @response.body
  end

  test "proposal calldata must encode the displayed owner change" do
    wallets = create_wallet(chain_ids: [ 10 ])
    post "/propose_multisig_tx", params: {
      wallet_id: wallets.first["id"], tx_type: "change_threshold",
      call_detail: THRESHOLD_1, evm_call_data: call_data("change_threshold", { new_threshold: 2 })
    }, headers: auth, as: :json
    assert_response :bad_request
    assert_equal "intent_mismatch", body["code"]
  end

  # 假的 JSON-RPC 节点：按 method 和 calldata 回答，calldata 不对（比如 0x0x 前缀）就报错，
  # 和真节点一样。owners: nil 表示地址上没有合约。
  def fake_chain(owners:, threshold: 1, down: false)
    lambda do |_chain_id, payload|
      next nil if down
      params = payload[:params]
      result =
        case [ payload[:method], params.first.is_a?(Hash) ? params.first[:data] : nil ]
        when [ "eth_getCode", nil ] then owners ? "0x6080" : "0x"
        when [ "eth_call", ChainRpc::SAFE_GET_OWNERS ]
          next { "result" => "0x" } unless owners
          words = [ 32, owners.length ] + owners.map { |a| a.delete_prefix("0x").to_i(16) }
          "0x" + words.map { |w| w.to_s(16).rjust(64, "0") }.join
        when [ "eth_call", ChainRpc::SAFE_GET_THRESHOLD ] then "0x" + threshold.to_s(16).rjust(64, "0")
        else next { "error" => { "code" => -32602, "message" => "invalid params #{params.inspect}" } }
        end
      { "result" => result }
    end
  end

  def sync(wallet_id, chain, **submitted)
    ChainRpc.stub(:rpc_request, chain) do
      post "/sync_multisig_wallet", params: { wallet_id: wallet_id, **submitted }, headers: auth, as: :json
    end
  end

  test "sync writes the owners and threshold read from chain" do
    wallet_id = create_wallet(chain_ids: [ 10 ]).first["id"]
    sync(wallet_id, fake_chain(owners: [ ALICE, BOB, CAROL ], threshold: 1))
    assert_response :success, @response.body
    wallet = Wallet.find(wallet_id)
    assert_equal [ ALICE, BOB, CAROL ], wallet.owner_address_list.sort
    assert_equal 1, wallet.threshold
  end

  test "sync refuses submitted owners that differ from chain" do
    wallet_id = create_wallet(chain_ids: [ 10 ]).first["id"]
    sync(wallet_id, fake_chain(owners: [ ALICE, BOB ], threshold: 2), owners: [ ALICE, CAROL ], threshold: 1)
    assert_equal "chain_mismatch", body["code"]
    wallet = Wallet.find(wallet_id)
    assert_equal [ ALICE, BOB ], wallet.owner_address_list.sort
    assert_equal 2, wallet.threshold
  end

  test "sync accepts submitted owners that match chain" do
    wallet_id = create_wallet(chain_ids: [ 10 ]).first["id"]
    sync(wallet_id, fake_chain(owners: [ ALICE, BOB ], threshold: 1), owners: [ BOB.upcase.sub("0X", "0x"), ALICE ], threshold: 1)
    assert_response :success, @response.body
    assert_equal 1, Wallet.find(wallet_id).threshold
  end

  test "sync uses the initial config when the Safe is not deployed" do
    wallet_id = create_wallet(chain_ids: [ 10 ]).first["id"]
    Wallet.find(wallet_id).update!(threshold: 1)
    sync(wallet_id, fake_chain(owners: nil))
    assert_response :success, @response.body
    assert_equal 2, Wallet.find(wallet_id).threshold
  end

  test "sync fails closed when the chain cannot be read" do
    wallet_id = create_wallet(chain_ids: [ 10 ]).first["id"]
    sync(wallet_id, fake_chain(owners: nil, down: true), owners: [ ALICE ], threshold: 1)
    assert_equal "chain_unavailable", body["code"]
    assert_equal [ ALICE, BOB ], Wallet.find(wallet_id).owner_address_list.sort
  end

  test "the owner who locked a tx can release it immediately, others must wait" do
    wallets = create_wallet(chain_ids: [ 10 ])
    wallet = Wallet.find(wallets.first["id"])
    tx = MultisigTransaction.create!(
      wallet: wallet, proposer: @alice, chain_id: 10, queue_position: 1, tx_type: "change_threshold",
      call_detail: THRESHOLD_1, evm_call_data: call_data("change_threshold", THRESHOLD_1), threshold_at_creation: 2,
      status: "ready", expires_at: 5.days.from_now, updated_at: 1.hour.ago
    )

    post "/execute_multisig_tx", params: { multisig_tx_id: tx.id }, headers: auth, as: :json
    assert_response :success, @response.body
    tx.reload
    assert_equal "executing", tx.status
    assert_equal @alice.id, tx.executor_id
    assert_operator tx.updated_at, :>, 1.minute.ago

    # 别人刚锁的交易，5 分钟内不能改回去
    post "/reset_executing_multisig_tx", params: { multisig_tx_id: tx.id }, headers: auth(@bob_token), as: :json
    assert_response :bad_request

    post "/reset_executing_multisig_tx", params: { multisig_tx_id: tx.id }, headers: auth, as: :json
    assert_response :success, @response.body
    assert_equal "ready", tx.reload.status
  end
end
