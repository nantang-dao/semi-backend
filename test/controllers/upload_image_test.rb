require "test_helper"

# 这些用例都停在真正发出上游请求之前 —— 校验不通过就不该碰 api.sola.day。
# 转发本身没有网络桩，故不在此覆盖。
class UploadImageTest < ActionDispatch::IntegrationTest
  setup do
    post signin_with_password_url, params: { phone: "19900001111", password: "hunter2" }
    @auth = { "Authorization" => "Bearer #{JSON.parse(@response.body)['auth_token']}" }
  end

  def png(name: "a.png", type: "image/png", bytes: "x")
    file = Tempfile.new([ "upload", ".png" ])
    file.binmode
    file.write(bytes)
    file.rewind
    Rack::Test::UploadedFile.new(file.path, type, original_filename: name)
  end

  test "没有 auth token 一律 401" do
    post upload_image_url, params: { file: png }
    assert_response :unauthorized
  end

  test "没带文件时报 No File Uploaded" do
    post upload_image_url, params: {}, headers: @auth
    assert_response :bad_request
    assert_equal "No File Uploaded", JSON.parse(@response.body)["message"]
  end

  test "非图片类型被拒绝" do
    post upload_image_url, params: { file: png(type: "application/pdf") }, headers: @auth
    assert_response :bad_request
    assert_equal "Unsupported Image Type", JSON.parse(@response.body)["message"]
  end

  test "超过大小上限被拒绝" do
    oversized = png(bytes: "0" * (ImageUploader::MAX_BYTES + 1))
    post upload_image_url, params: { file: oversized }, headers: @auth
    assert_response :bad_request
    assert_equal "Image Too Large", JSON.parse(@response.body)["message"]
  end

  test "未配置 SOLA_AUTH_TOKEN 时不发请求，直接抛 UploadError" do
    original = ENV["SOLA_AUTH_TOKEN"]
    ENV["SOLA_AUTH_TOKEN"] = nil
    error = assert_raises(ImageUploader::UploadError) do
      ImageUploader.upload(io: StringIO.new("x"), filename: "a.png", content_type: "image/png")
    end
    assert_match "SOLA_AUTH_TOKEN", error.message
  ensure
    ENV["SOLA_AUTH_TOKEN"] = original
  end
end
