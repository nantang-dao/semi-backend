# frozen_string_literal: true

require "http"

# 图片上传代理。
#
# 之前前端直接把文件 POST 到 api.sola.day，并且把 Sola 的 auth_token 打进了
# 客户端 bundle —— 那是一条无 exp 的 JWT，任何人打开 devtools 都能拿走。
# 现在文件先到 Semi 后端，由后端用服务端保管的凭证转发上去，凭证不再下发。
class ImageUploader
  ENDPOINT = "https://api.sola.day/service/upload_image"
  MAX_BYTES = 5 * 1024 * 1024
  ALLOWED_TYPES = %w[image/png image/jpeg image/webp image/gif].freeze
  TIMEOUT_SECONDS = 30

  class UploadError < StandardError; end

  # 上传成功返回图床 URL，失败一律抛 UploadError（上游细节只进日志，不回给客户端）。
  def self.upload(io:, filename:, content_type:)
    token = ENV["SOLA_AUTH_TOKEN"]
    raise UploadError, "SOLA_AUTH_TOKEN is not configured" if token.blank?

    form = {
      auth_token: token,
      uploader: "user",
      resource: SecureRandom.alphanumeric(8).downcase,
      data: HTTP::FormData::File.new(io, filename: filename, content_type: content_type)
    }

    response = HTTP.timeout(TIMEOUT_SECONDS).post(ENDPOINT, form: form)
    unless response.status.success?
      raise UploadError, "upstream returned HTTP #{response.code}"
    end

    url = parse_url(response.to_s)
    raise UploadError, "upstream returned no url" if url.blank?
    url
  rescue HTTP::Error, JSON::ParserError => e
    raise UploadError, "upstream request failed: #{e.class}: #{e.message}"
  end

  def self.parse_url(body)
    JSON.parse(body).dig("result", "url")
  rescue JSON::ParserError
    raise UploadError, "upstream returned a non-JSON body"
  end
  private_class_method :parse_url
end
