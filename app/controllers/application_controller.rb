class AppError < StandardError
  attr_reader :code, :data

  def initialize(message, code: nil, data: {})
    super(message)
    @code = code
    @data = data || {}
  end
end

class AuthError < AppError
end

class ApplicationController < ActionController::API
    # 当前请求的 AuthToken 记录。登出要吊销的是**这一个**，不是该用户的全部。
    def current_auth_token
        return @current_auth_token if defined?(@current_auth_token)

        @current_auth_token = begin
            header = request.headers["Authorization"]
            if header && header.start_with?("Bearer ")
                token = header.split(" ", 2)[1]
                # usable：未吊销且未过期。disabled 这个列一直存在，但此前没有
                # 任何地方检查它 —— 等于一个没接线的开关。
                found = AuthToken.usable.find_by(token: token) if token.present?
                found&.touch_last_used!
                found
            end
        end
    end

    def current_user
        return @current_user if @current_user

        @current_user = current_auth_token&.user
    end

    def authenticate_user
        raise AuthError.new("Unauthorized") unless current_user
        current_user
    end

    rescue_from AppError do |err|
        Rails.logger.info err.message
        body = { result: "error", message: err.message }
        body[:code] = err.code if err.code.present?
        body.merge!(err.data) if err.data.present?
        render json: body, status: 400
    end

    rescue_from AuthError do |err|
        render json: { result: "error", message: err.message }, status: 401
    end
end
