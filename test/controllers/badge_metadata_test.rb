require "test_helper"

# metadata 是 jsonb 列，而 Rails 收到的嵌套参数是 ActionController::Parameters。
# 这两条确认真实内容能原样存进去、读得回来 —— 用空 hash 试不出这个问题。
class BadgeMetadataTest < ActionDispatch::IntegrationTest
  OWNER = "0xAbC0000000000000000000000000000000000123".freeze

  setup do
    @original = ENV["BADGE_SERVICE_TOKEN"]
    ENV["BADGE_SERVICE_TOKEN"] = "t"
    @headers = { "X-Service-Token" => "t", "CONTENT_TYPE" => "application/json" }
  end

  teardown { ENV["BADGE_SERVICE_TOKEN"] = @original }

  def node(seed)
    "0x" + Digest::SHA256.hexdigest(seed)
  end

  test "create_class 的 metadata 原样落库" do
    post "/badge/classes",
         params: {
           class_id: node("c"), chain_id: 10, profile_id: node("p"),
           wallet_address: OWNER, badge_contract_address: OWNER,
           metadata: { class_name: "n", class_description: "d", class_image_url: "u" }
         }.to_json,
         headers: @headers

    assert_response :success
    assert_equal "n", BadgeClass.first.metadata["class_name"]
    assert_equal "u", BadgeClass.first.metadata["class_image_url"]
  end

  test "create_badges 的 metadata 原样落库" do
    post "/badge/items",
         params: {
           chain_id: 10,
           badges: [ {
             badge_id: node("b"), class_id: node("c"), wallet_address: OWNER,
             metadata: { badge_name: "n", badge_image_url: "u" }
           } ]
         }.to_json,
         headers: @headers

    assert_response :success
    assert_equal "n", Badge.first.metadata["badge_name"]
    assert_equal "u", Badge.first.metadata["badge_image_url"]
  end
end
