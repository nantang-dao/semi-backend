require "test_helper"

class BadgesControllerTest < ActionDispatch::IntegrationTest
  SERVICE_TOKEN = "test-badge-service-token".freeze
  # checksummed 形态，混合大小写 —— 参与 namehash，不能被 normalize
  OWNER = "0xAbC0000000000000000000000000000000000123".freeze
  CONTRACT = "0x00000000000000000000000000000000000000ff".freeze

  setup do
    @original_token = ENV["BADGE_SERVICE_TOKEN"]
    ENV["BADGE_SERVICE_TOKEN"] = SERVICE_TOKEN
    @headers = { "X-Service-Token" => SERVICE_TOKEN }
  end

  teardown do
    ENV["BADGE_SERVICE_TOKEN"] = @original_token
  end

  def node(seed)
    "0x" + Digest::SHA256.hexdigest(seed)
  end

  def body
    JSON.parse(@response.body)
  end

  def make_badge(status: "pending", address: OWNER, chain_id: 10, seed: SecureRandom.hex(4))
    Badge.create!(
      badge_id: node(seed), class_id: node("class-#{seed}"),
      wallet_address: address, chain_id: chain_id, status: status, metadata: { badge_name: "n" }
    )
  end

  # ---------- 服务认证 ----------

  test "没有 X-Service-Token 一律 401" do
    get "/badge/owned", params: { wallet_address: OWNER, chain_id: 10 }
    assert_response :unauthorized
  end

  test "token 不对也是 401" do
    get "/badge/owned", params: { wallet_address: OWNER, chain_id: 10 },
        headers: { "X-Service-Token" => "wrong" }
    assert_response :unauthorized
  end

  test "服务端没配置 token 时拒绝所有请求，而不是放行" do
    ENV["BADGE_SERVICE_TOKEN"] = nil
    get "/badge/owned", params: { wallet_address: OWNER, chain_id: 10 }, headers: @headers
    assert_response :unauthorized
  end

  # ---------- 入参校验 ----------

  test "形态不对的 node id 被挡在库外" do
    post "/badge/profile",
         params: { profile_id: "0xdeadbeef", wallet_address: OWNER, chain_id: 10 },
         headers: @headers
    assert_response :bad_request
    assert_equal "Invalid profile_id", body["message"]
    assert_equal 0, BadgeProfile.count
  end

  test "形态不对的地址被挡住" do
    post "/badge/profile",
         params: { profile_id: node("p"), wallet_address: "not-an-address", chain_id: 10 },
         headers: @headers
    assert_response :bad_request
    assert_equal "Invalid wallet_address", body["message"]
  end

  test "缺 chain_id 报明确的错" do
    get "/badge/owned", params: { wallet_address: OWNER }, headers: @headers
    assert_response :bad_request
    assert_equal "Missing chain_id", body["message"]
  end

  # ---------- 读 ----------

  test "owned 只返回 accepted，pending 只返回 pending" do
    accepted = make_badge(status: "accepted")
    pending = make_badge(status: "pending")
    make_badge(status: "rejected")

    get "/badge/owned", params: { wallet_address: OWNER, chain_id: 10 }, headers: @headers
    assert_equal [ accepted.badge_id ], body["badges"].map { |b| b["badge_id"] }

    get "/badge/pending", params: { wallet_address: OWNER, chain_id: 10 }, headers: @headers
    assert_equal [ pending.badge_id ], body["badges"].map { |b| b["badge_id"] }
  end

  test "用小写地址也能查到 checksummed 存储的徽章" do
    badge = make_badge(status: "accepted")
    get "/badge/owned", params: { wallet_address: OWNER.downcase, chain_id: 10 }, headers: @headers
    assert_equal [ badge.badge_id ], body["badges"].map { |b| b["badge_id"] }
  end

  test "历史遗留的全小写地址徽章，持有人用 checksummed 也能查到" do
    badge = make_badge(status: "pending", address: OWNER.downcase)
    get "/badge/pending", params: { wallet_address: OWNER, chain_id: 10 }, headers: @headers
    assert_equal [ badge.badge_id ], body["badges"].map { |b| b["badge_id"] }
  end

  test "链隔离：另一条链上的徽章查不到" do
    make_badge(status: "accepted", chain_id: 11155111)
    get "/badge/owned", params: { wallet_address: OWNER, chain_id: 10 }, headers: @headers
    assert_empty body["badges"]
  end

  # ---------- 写 ----------

  test "create_profile 幂等，重复调用不新增行" do
    2.times do
      post "/badge/profile",
           params: { profile_id: node("p"), wallet_address: OWNER, chain_id: 10, tx_hash: "0xaa" },
           headers: @headers
      assert_response :success
    end
    assert_equal 1, BadgeProfile.count
  end

  test "写入的地址原样保存，不被 normalize" do
    post "/badge/profile",
         params: { profile_id: node("p"), wallet_address: OWNER, chain_id: 10 },
         headers: @headers
    assert_equal OWNER, BadgeProfile.first.wallet_address
  end

  test "批量发放整批成功或整批失败" do
    good = { badge_id: node("b1"), class_id: node("c"), wallet_address: OWNER, metadata: {} }
    bad  = { badge_id: "0xnope",   class_id: node("c"), wallet_address: OWNER, metadata: {} }

    post "/badge/items", params: { chain_id: 10, badges: [ good, bad ] }, headers: @headers
    assert_response :bad_request
    assert_equal 0, Badge.count, "有一条不合法时整批都不该落库"

    post "/badge/items", params: { chain_id: 10, badges: [ good ] }, headers: @headers
    assert_response :success
    assert_equal 1, Badge.count
    assert_equal "pending", Badge.first.status
  end

  # ---------- accept / reject ----------

  test "accept 把 pending 变成 accepted 并记下 tx_hash" do
    badge = make_badge
    post "/badge/accept",
         params: { badge_id: badge.badge_id, wallet_address: OWNER, chain_id: 10, tx_hash: "0xmint" },
         headers: @headers
    assert_response :success
    assert_equal "accepted", badge.reload.status
    assert_equal "0xmint", badge.tx_hash
  end

  test "不是持有人不能 accept" do
    badge = make_badge
    post "/badge/accept",
         params: { badge_id: badge.badge_id, wallet_address: CONTRACT, chain_id: 10 },
         headers: @headers
    assert_response :bad_request
    assert_equal "Badge Is Not Owned By The User", body["message"]
    assert_equal "pending", badge.reload.status
  end

  test "持有人地址大小写不同也能 accept —— 正是卡住那 4 枚徽章的场景" do
    badge = make_badge(address: OWNER.downcase)
    post "/badge/accept",
         params: { badge_id: badge.badge_id, wallet_address: OWNER, chain_id: 10, tx_hash: "0xmint" },
         headers: @headers
    assert_response :success
    assert_equal "accepted", badge.reload.status
  end

  test "已经 accepted 的徽章不能再 accept —— 防重复 mint" do
    badge = make_badge
    params = { badge_id: badge.badge_id, wallet_address: OWNER, chain_id: 10, tx_hash: "0x1" }

    post "/badge/accept", params: params, headers: @headers
    assert_response :success

    post "/badge/accept", params: params.merge(tx_hash: "0x2"), headers: @headers
    assert_response :bad_request
    assert_equal "Badge Is Not Pending", body["message"]
    assert_equal "0x1", badge.reload.tx_hash, "第二次不该覆盖第一次的 tx_hash"
  end

  test "跨链 accept 被拒绝" do
    badge = make_badge(chain_id: 10)
    post "/badge/accept",
         params: { badge_id: badge.badge_id, wallet_address: OWNER, chain_id: 11155111 },
         headers: @headers
    assert_response :bad_request
    assert_equal "Badge Is Not On This Chain", body["message"]
  end

  test "reject 之后不能再 accept" do
    badge = make_badge
    params = { badge_id: badge.badge_id, wallet_address: OWNER, chain_id: 10 }

    post "/badge/reject", params: params, headers: @headers
    assert_response :success
    assert_equal "rejected", badge.reload.status

    post "/badge/accept", params: params, headers: @headers
    assert_response :bad_request
  end

  # ---------- summary / details ----------

  test "summary 把 owned 和 pending 分开返回，并带上该 profile 的 classes" do
    accepted = make_badge(status: "accepted")
    pending = make_badge(status: "pending")
    klass = BadgeClass.create!(
      class_id: node("k"), chain_id: 10, profile_id: node("p"),
      wallet_address: OWNER, badge_contract_address: CONTRACT, metadata: {}
    )

    get "/badge/summary",
        params: { wallet_address: OWNER, chain_id: 10, profile_id: node("p") },
        headers: @headers
    assert_response :success
    assert_equal [ accepted.badge_id ], body["owned"].map { |b| b["badge_id"] }
    assert_equal [ pending.badge_id ], body["pending"].map { |b| b["badge_id"] }
    assert_equal [ klass.class_id ], body["badge_classes"].map { |c| c["class_id"] }
  end

  test "classes 按 profile_id 过滤，不会带出 profile_id 对不上的脏行" do
    mine = BadgeClass.create!(
      class_id: node("k1"), chain_id: 10, profile_id: node("p"),
      wallet_address: OWNER, badge_contract_address: CONTRACT, metadata: {}
    )
    # 同一个钱包地址，但 profile_id 是另一个值 —— 生产数据里确实有这种行
    BadgeClass.create!(
      class_id: node("k2"), chain_id: 10, profile_id: node("other"),
      wallet_address: OWNER, badge_contract_address: CONTRACT, metadata: {}
    )

    get "/badge/classes", params: { chain_id: 10, profile_id: node("p") }, headers: @headers
    assert_response :success
    assert_equal [ mine.class_id ], body["badge_classes"].map { |c| c["class_id"] }
  end

  test "找不到的 class 返回 400 而不是空对象" do
    get "/badge/classes/details", params: { class_id: node("nope"), chain_id: 10 }, headers: @headers
    assert_response :bad_request
    assert_equal "Badge Class Not Found", body["message"]
  end

  test "按 badge_id 单查，供 NFT metadata 路由使用" do
    badge = make_badge(status: "accepted")
    get "/badge/item", params: { badge_id: badge.badge_id }, headers: @headers
    assert_response :success
    assert_equal badge.badge_id, body["badge"]["badge_id"]
    assert_equal "n", body["badge"]["metadata"]["badge_name"]
  end
end
