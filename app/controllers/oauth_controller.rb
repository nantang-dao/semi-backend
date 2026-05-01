class OauthController < ApplicationController
  # GET /.well-known/openid-configuration
  def openid_configuration
    base = ENV.fetch("APP_BASE_URL", "https://semi.fly.dev")
    render json: {
      issuer: base,
      authorization_endpoint: "#{base}/oauth/authorize",
      token_endpoint: "#{base}/oauth/token",
      userinfo_endpoint: "#{base}/oauth/userinfo",
      revocation_endpoint: "#{base}/oauth/revoke",
      jwks_uri: "#{base}/oauth/jwks",
      response_types_supported: [ "code" ],
      grant_types_supported: [ "authorization_code", "refresh_token" ],
      subject_types_supported: [ "public" ],
      id_token_signing_alg_values_supported: [ "RS256" ],
      scopes_supported: OauthApplication::VALID_SCOPES,
      token_endpoint_auth_methods_supported: [ "client_secret_post" ],
      code_challenge_methods_supported: [ "S256" ]
    }
  end

  # GET /oauth/authorize
  # Validates params and returns app info JSON for the frontend consent page.
  def authorize_info
    app = find_application!(params[:client_id])
    raise AppError.new("Application is not active") unless app.status == "active"
    validate_redirect_uri!(app, params[:redirect_uri])
    validate_scopes!(app, params[:scope]&.split)
    raise AppError.new("response_type must be 'code'") unless params[:response_type] == "code"
    raise AppError.new("code_challenge is required") if params[:code_challenge].blank?
    raise AppError.new("code_challenge_method must be S256") unless params[:code_challenge_method] == "S256"

    render json: {
      client_id: app.client_id,
      app_name: app.name,
      scopes: params[:scope]&.split || [],
      redirect_uri: params[:redirect_uri]
    }
  end

  # POST /oauth/authorize
  # Authenticated user accepts or denies the authorization request.
  def authorize_decision
    user = authenticate_user

    redirect_uri = params[:redirect_uri]
    state = params[:state]

    if params[:action_choice] == "deny"
      uri = append_query(redirect_uri, error: "access_denied", state: state)
      return render json: { redirect_to: uri }
    end

    app = find_application!(params[:client_id])
    raise AppError.new("Application is not active") unless app.status == "active"
    validate_redirect_uri!(app, redirect_uri)
    requested_scopes = params[:scope]&.split || []
    validate_scopes!(app, requested_scopes)

    OauthGrant.upsert_for(user: user, application: app, scopes: requested_scopes)

    auth_code = OauthAuthorizationCode.create!(
      user: user,
      oauth_application: app,
      scopes: requested_scopes,
      redirect_uri: redirect_uri,
      code_challenge: params[:code_challenge],
      code_challenge_method: params[:code_challenge_method] || "S256"
    )

    render json: { code: auth_code.code, redirect_uri: redirect_uri, state: state }
  end

  # POST /oauth/token
  def token
    case params[:grant_type]
    when "authorization_code" then handle_authorization_code_grant
    when "refresh_token"      then handle_refresh_token_grant
    else
      render json: { error: "unsupported_grant_type" }, status: 400
    end
  end

  # GET /oauth/userinfo
  def userinfo
    at = authenticate_oauth_token
    user = at.user
    scopes = at.scopes

    claims = { sub: user.id }
    if scopes.include?("profile")
      claims.merge!(
        handle: user.handle,
        phone_verified: user.phone_verified,
        email_verified: user.email.present?
      )
    end
    claims[:wallet_address] = user.evm_chain_address if scopes.include?("wallet")
    claims[:scopes_granted] = scopes

    render json: claims
  end

  # POST /oauth/revoke
  def revoke
    token_value = params[:token]
    if (at = OauthAccessToken.find_by(token: token_value))
      at.revoke!
    elsif (rt = OauthRefreshToken.find_by(token: token_value))
      rt.revoke!
      rt.oauth_access_token.update!(revoked_at: Time.current)
    end
    render json: { result: "ok" }
  end

  # GET /oauth/jwks
  def jwks
    key = SemiOAuth.public_key
    unless key
      return render json: { keys: [] }
    end
    n = Base64.urlsafe_encode64(key.n.to_s(2), padding: false)
    e = Base64.urlsafe_encode64(key.e.to_s(2), padding: false)
    render json: {
      keys: [ { kty: "RSA", use: "sig", alg: "RS256", kid: SemiOAuth.key_id, n: n, e: e } ]
    }
  end

  # POST /oauth/applications
  def create_application
    user = authenticate_user
    app, raw_secret = OauthApplication.create_with_secret(
      name: params[:name],
      redirect_uris: Array(params[:redirect_uris]),
      allowed_scopes: Array(params[:allowed_scopes]),
      owner: user
    )
    render json: { result: "ok", application: app_json(app), client_secret: raw_secret }, status: 201
  end

  # GET /oauth/applications
  def list_applications
    user = authenticate_user
    apps = OauthApplication.where(owner: user)
    render json: { result: "ok", applications: apps.map { |a| app_json(a) } }
  end

  # PATCH /oauth/applications/:id
  def update_application
    user = authenticate_user
    app = OauthApplication.find_by!(id: params[:id], owner: user)
    app.update!(
      name:           params.fetch(:name,           app.name),
      redirect_uris:  params.fetch(:redirect_uris,  app.redirect_uris),
      allowed_scopes: params.fetch(:allowed_scopes, app.allowed_scopes),
      status:         params.fetch(:status,         app.status)
    )
    render json: { result: "ok", application: app_json(app) }
  end

  # DELETE /oauth/applications/:id
  def destroy_application
    user = authenticate_user
    app = OauthApplication.find_by!(id: params[:id], owner: user)
    app.destroy!
    render json: { result: "ok" }
  end

  # GET /oauth/grants
  def list_grants
    user = authenticate_user
    grants = OauthGrant.includes(:oauth_application).where(user: user)
    render json: {
      result: "ok",
      grants: grants.map { |g|
        {
          id: g.id,
          app_name: g.oauth_application.name,
          client_id: g.oauth_application.client_id,
          scopes: g.scopes,
          created_at: g.created_at
        }
      }
    }
  end

  # DELETE /oauth/grants/:id
  def destroy_grant
    user = authenticate_user
    grant = OauthGrant.find_by!(id: params[:id], user: user)
    OauthAccessToken.where(user: user, oauth_application: grant.oauth_application)
                    .where(revoked_at: nil)
                    .find_each(&:revoke!)
    grant.destroy!
    render json: { result: "ok" }
  end

  private

  def find_application!(client_id)
    OauthApplication.find_by(client_id: client_id) ||
      raise(AppError.new("Unknown client_id"))
  end

  def validate_redirect_uri!(app, uri)
    raise AppError.new("redirect_uri is required") if uri.blank?
    raise AppError.new("redirect_uri not registered") unless app.redirect_uri_allowed?(uri)
  end

  def validate_scopes!(app, scopes)
    invalid = Array(scopes) - OauthApplication::VALID_SCOPES
    raise AppError.new("Invalid scopes: #{invalid.join(", ")}") if invalid.any?
    raise AppError.new("Scopes not allowed for this client") unless app.scopes_allowed?(Array(scopes))
  end

  def handle_authorization_code_grant
    code_record = OauthAuthorizationCode.valid.find_by(code: params[:code])
    raise AppError.new("Invalid or expired authorization code") unless code_record

    app = find_application!(params[:client_id])
    raise AppError.new("client_id mismatch") unless code_record.application_id == app.id
    raise AppError.new("redirect_uri mismatch") unless code_record.redirect_uri == params[:redirect_uri]

    code_record.verify_pkce!(params[:code_verifier].to_s)
    code_record.update!(used: true)

    access_token = OauthAccessToken.issue(user: code_record.user, application: app, scopes: code_record.scopes)
    refresh_token = OauthRefreshToken.issue(user: code_record.user, application: app, access_token: access_token)

    render json: token_response(access_token, refresh_token)
  end

  def handle_refresh_token_grant
    rt = OauthRefreshToken.find_by(token: params[:refresh_token])
    unless rt&.active?
      if rt&.revoked_at.present?
        OauthAccessToken.where(user: rt.user, oauth_application: rt.oauth_application)
                        .where(revoked_at: nil).find_each(&:revoke!)
      end
      raise AppError.new("Invalid or expired refresh_token")
    end
    new_access, new_refresh = rt.rotate!
    render json: token_response(new_access, new_refresh)
  end

  def token_response(access_token, refresh_token)
    {
      access_token: access_token.token,
      token_type: "Bearer",
      expires_in: OauthAccessToken::TTL.to_i,
      refresh_token: refresh_token.token,
      scope: access_token.scopes.join(" ")
    }
  end

  def authenticate_oauth_token
    header = request.headers["Authorization"]
    raise AuthError.new("Missing bearer token") unless header&.start_with?("Bearer ")
    token_value = header.split(" ", 2)[1]
    at = OauthAccessToken.find_by(token: token_value)
    raise AuthError.new("Invalid or expired access token") unless at&.active?
    at
  end

  def append_query(uri, **params)
    u = URI.parse(uri)
    query = URI.decode_www_form(u.query.to_s)
    params.each { |k, v| query << [ k.to_s, v.to_s ] if v.present? }
    u.query = URI.encode_www_form(query)
    u.to_s
  end

  def app_json(app)
    {
      id: app.id, client_id: app.client_id, name: app.name,
      redirect_uris: app.redirect_uris, allowed_scopes: app.allowed_scopes,
      status: app.status, created_at: app.created_at
    }
  end
end
