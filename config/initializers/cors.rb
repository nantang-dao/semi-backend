Rails.application.config.middleware.insert_before 0, Rack::Cors do
  allow do
    # Semi's own frontend — all routes
    origins "https://semi.fly.dev", "https://semi-production.fly.dev", "http://localhost:3001", "http://localhost:3000"
    resource "*", headers: :any, methods: [ :get, :post, :put, :patch, :delete, :options, :head ]
  end

  allow do
    # Third-party OAuth clients — only the public OAuth endpoints
    origins "*"
    resource "/oauth/token",    headers: :any, methods: [ :post, :options ]
    resource "/oauth/userinfo", headers: :any, methods: [ :get, :options ]
    resource "/oauth/revoke",   headers: :any, methods: [ :post, :options ]
    resource "/oauth/jwks",     headers: :any, methods: [ :get, :options ]
    resource "/.well-known/openid-configuration", headers: :any, methods: [ :get, :options ]
  end
end
