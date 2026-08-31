class BadgesController < ApplicationController
  # 徽章数据从 InstantDB 迁过来之后的读写入口。
  #
  # 调用方只有 semi-app 的 Nitro 层：它负责验签、算 namehash id、以及用 admin
  # 私钥上链；Rails 只管数据。链上那部分**不搬进来** —— 后端不持有私钥、不签名
  # 是这个仓库的既有约束。
  #
  # 所以 id（profile_id / class_id / badge_id）一律由调用方算好传进来，
  # Rails 不做 keccak，只校验形态。
  before_action :authenticate_service

  NODE_FORMAT = /\A0x[0-9a-fA-F]{64}\z/
  ADDRESS_FORMAT = /\A0x[0-9a-fA-F]{40}\z/

  # ---------- profiles ----------

  def show_profile
    profile = BadgeProfile.for_wallet(required(:wallet_address), chain_id).first
    render json: { result: "ok", profile: profile && serialize_profile(profile) }
  end

  def create_profile
    profile = BadgeProfile.find_or_initialize_by(profile_id: node_param(:profile_id))
    profile.assign_attributes(
      wallet_address: address_param(:wallet_address),
      chain_id: chain_id,
      tx_hash: params[:tx_hash]
    )
    save!(profile)
    render json: { result: "ok", profile: serialize_profile(profile) }
  end

  # ---------- classes ----------

  # 按 profile_id 而不是按地址过滤。库里存在 profile_id 指向不存在 profile 的
  # 脏行（有一条的 profile_id 和 class_id 都是 keccak256("")），按地址查会把它
  # 带出来。summary 一直是按 profile_id 查的，两边保持一致。
  def list_classes
    classes = BadgeClass.where(profile_id: node_param(:profile_id), chain_id: chain_id)
                        .order(created_at: :desc)
    render json: { result: "ok", badge_classes: classes.map { |c| serialize_class(c) } }
  end

  def class_details
    klass = BadgeClass.find_by(class_id: node_param(:class_id), chain_id: chain_id)
    raise AppError.new("Badge Class Not Found") unless klass
    render json: { result: "ok", badge_class: serialize_class(klass) }
  end

  def create_class
    klass = BadgeClass.find_or_initialize_by(class_id: node_param(:class_id))
    klass.assign_attributes(
      chain_id: chain_id,
      profile_id: node_param(:profile_id),
      wallet_address: address_param(:wallet_address),
      badge_contract_address: address_param(:badge_contract_address),
      metadata: params[:metadata] || {},
      tx_hash: params[:tx_hash]
    )
    save!(klass)
    render json: { result: "ok", badge_class: serialize_class(klass) }
  end

  # ---------- badges ----------

  def owned
    render json: { result: "ok", badges: wallet_badges.owned.map { |b| serialize_badge(b) } }
  end

  def pending
    render json: { result: "ok", badges: wallet_badges.pending.map { |b| serialize_badge(b) } }
  end

  def summary
    badges = wallet_badges.where(status: %w[accepted pending]).to_a
    classes = BadgeClass.where(profile_id: node_param(:profile_id), chain_id: chain_id)

    render json: {
      result: "ok",
      owned: badges.select { |b| b.status == "accepted" }.map { |b| serialize_badge(b) },
      pending: badges.select { |b| b.status == "pending" }.map { |b| serialize_badge(b) },
      badge_classes: classes.map { |c| serialize_class(c) }
    }
  end

  # NFT metadata 路由用：按 badge_id 单查
  def show_badge
    badge = Badge.find_by(badge_id: node_param(:badge_id))
    raise AppError.new("Badge Not Found") unless badge
    render json: { result: "ok", badge: serialize_badge(badge) }
  end

  # 批量发放。整批放在一个事务里 —— Instant 那边也是一次 transact，
  # 半批成功会让发送方无从判断到底发出去了几枚。
  def create_badges
    items = params[:badges]
    raise AppError.new("No Badges Given") unless items.is_a?(Array) && items.any?

    created = ActiveRecord::Base.transaction do
      items.map do |item|
        badge = Badge.find_or_initialize_by(badge_id: fetch_node(item, :badge_id))
        badge.assign_attributes(
          class_id: fetch_node(item, :class_id),
          wallet_address: fetch_address(item, :wallet_address),
          chain_id: chain_id,
          metadata: item[:metadata] || {},
          status: "pending"
        )
        save!(badge)
        badge
      end
    end

    render json: { result: "ok", badges: created.map { |b| serialize_badge(b) } }
  end

  def accept
    badge = claim_pending_badge!
    # 条件更新而不是先读后写：两个请求同时进来时，只有一个能把 pending 抢走，
    # 另一个拿到 0 行，不会重复 mint。
    updated = Badge.where(id: badge.id, status: "pending")
                   .update_all(status: "accepted", tx_hash: params[:tx_hash], updated_at: Time.current)
    raise AppError.new("Badge Is Not Pending") if updated.zero?

    render json: { result: "ok", badge: serialize_badge(badge.reload) }
  end

  def reject
    badge = claim_pending_badge!
    updated = Badge.where(id: badge.id, status: "pending")
                   .update_all(status: "rejected", updated_at: Time.current)
    raise AppError.new("Badge Is Not Pending") if updated.zero?

    render json: { result: "ok", badge: serialize_badge(badge.reload) }
  end

  private

  # Nitro 是唯一调用方。这里不是用户认证 —— 用户的签名验证在 Nitro 侧完成，
  # Rails 信任的是「请求来自 Nitro」这一件事。
  def authenticate_service
    expected = ENV["BADGE_SERVICE_TOKEN"]
    raise AuthError.new("Badge service is not configured") if expected.blank?

    given = request.headers["X-Service-Token"].to_s
    unless ActiveSupport::SecurityUtils.secure_compare(given, expected)
      raise AuthError.new("Unauthorized")
    end
  end

  def required(key)
    value = params[key].presence
    raise AppError.new("Missing #{key}") unless value
    value
  end

  def chain_id
    value = required(:chain_id).to_i
    raise AppError.new("Invalid chain_id") if value.zero?
    value
  end

  def node_param(key)
    fetch_node(params, key)
  end

  def address_param(key)
    fetch_address(params, key)
  end

  # id 是链上标识，形态不对就别让它进库 —— 进去之后没人能发现。
  def fetch_node(source, key)
    value = source[key].to_s
    raise AppError.new("Invalid #{key}") unless value.match?(NODE_FORMAT)
    value
  end

  # 地址原样保存：它是 namehash 的输入，改大小写等于换了一个 id。
  def fetch_address(source, key)
    value = source[key].to_s
    raise AppError.new("Invalid #{key}") unless value.match?(ADDRESS_FORMAT)
    value
  end

  def wallet_badges
    Badge.for_wallet(required(:wallet_address), chain_id)
  end

  # accept / reject 共用：找到徽章并确认调用方就是持有人。
  def claim_pending_badge!
    badge = Badge.find_by(badge_id: node_param(:badge_id))
    raise AppError.new("Badge Not Found") unless badge
    raise AppError.new("Badge Is Not On This Chain") unless badge.chain_id == chain_id

    # 大小写不敏感：库里有历史遗留的全小写收件人地址。
    unless badge.wallet_address.casecmp?(required(:wallet_address))
      raise AppError.new("Badge Is Not Owned By The User")
    end

    badge
  end

  def save!(record)
    return if record.save
    raise AppError.new(record.errors.full_messages.join(", "))
  end

  def serialize_profile(profile)
    profile.as_json(only: [ :id, :profile_id, :wallet_address, :chain_id, :tx_hash, :created_at ])
  end

  def serialize_class(klass)
    klass.as_json(only: [ :id, :class_id, :chain_id, :profile_id, :wallet_address,
                          :badge_contract_address, :metadata, :tx_hash, :created_at ])
  end

  def serialize_badge(badge)
    badge.as_json(only: [ :id, :badge_id, :class_id, :wallet_address, :metadata,
                          :chain_id, :tx_hash, :status, :created_at ])
  end
end
