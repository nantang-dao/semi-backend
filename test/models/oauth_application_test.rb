require "test_helper"

class OauthApplicationTest < ActiveSupport::TestCase
  setup { @owner = User.create!(handle: "dev-#{SecureRandom.hex(3)}") }

  def build(redirect_uris)
    OauthApplication.new(name: "app", owner: @owner, client_secret_digest: "x", redirect_uris: redirect_uris)
  end

  test "新应用默认已上线" do
    app, = OauthApplication.create_with_secret(name: "app", owner: @owner, redirect_uris: [ "https://a.example/cb" ])
    assert_equal "active", app.status
  end

  test "接受多个 http(s) 回调地址，也接受按行分隔的字符串" do
    app = build("https://a.example/cb\r\n  http://localhost:3000/callback?x=1 \n\nhttps://a.example/cb")
    assert app.valid?, app.errors.full_messages.inspect
    assert_equal [ "https://a.example/cb", "http://localhost:3000/callback?x=1" ], app.redirect_uris
  end

  test "拒绝非 http(s) 协议和畸形地址" do
    [
      "javascript:alert(document.cookie)//",
      "JavaScript://x/%0aalert(1)",
      "data:text/html,<script>alert(1)</script>",
      "vbscript:msgbox(1)",
      "file:///etc/passwd",
      "//evil.example/cb",
      "https://",
      "https://user:pass@a.example/cb",
      "https://a.example/cb#frag",
      "https://a.example/c b",
      "not a url"
    ].each do |uri|
      app = build([ uri ])
      assert_not app.valid?, uri
      assert app.errors[:redirect_uris].any?, uri
    end
  end

  test "至少一个、至多十个" do
    assert_not build([]).valid?
    assert_not build((1..11).map { |i| "https://a.example/#{i}" }).valid?
    assert build((1..10).map { |i| "https://a.example/#{i}" }).valid?
  end

  test "校验上线前存进去的非法地址不再放行" do
    app, = OauthApplication.create_with_secret(name: "app", owner: @owner, redirect_uris: [ "https://a.example/cb" ])
    app.update_column(:redirect_uris, [ "https://a.example/cb", "javascript:alert(1)" ])
    assert app.redirect_uri_allowed?("https://a.example/cb")
    assert_not app.redirect_uri_allowed?("javascript:alert(1)")
    assert_not app.redirect_uri_allowed?("https://a.example/cb/other")
  end
end
