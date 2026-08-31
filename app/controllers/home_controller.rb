class HomeController < ApplicationController
  def index
    render json: { message: "Hello, World!" }
  end

  def send_sms
    code = rand(100_000..999_999)
    phone = params[:phone]
    VerificationToken.create(context: "phone-login", sent_to: phone, code: code, expires_at: Time.now + 15.minutes)
    if ENV["SMS_ENABLED"] == "ENABLED"
      begin
        response = SendSms.send_sms_aliyun(phone, code)
        Rails.logger.info("SMS sent response: #{response}")
      rescue => e
        Rails.logger.error("Error sending SMS: #{e.message}")
      end
  end
    Rails.logger.info("phone: #{phone}, code: #{code}")
    render json: { result: "ok", code: code }
  end

  def send_email
    code = rand(100_000..999_999)
    email = params[:email]
    VerificationToken.create(context: "email-login", sent_to: email, code: code, expires_at: Time.now + 60.minutes)

    mailer = SigninMailer.with(code: code, recipient: email).signin
    mailer.deliver_now!

    render json: { result: "ok", email: params[:email] }
  end

  def signin
    phone = params[:phone]
    code = params[:code]
    token = VerificationToken.find_by(context: "phone-login", sent_to: phone, code: code, used: false)

    raise AppError.new("Invalid Phone Or Code") unless token
    raise AppError.new("Code Expired") if DateTime.now > token.expires_at

    token.update(used: true)

    user = User.find_or_create_by(phone: phone)
    user.update(phone_verified: true) if user.phone_verified == false
    render json: { result: "ok", auth_token: user.gen_auth_token, phone: params[:phone], id: user.id, address_type: "phone" }
  end

  def signin_with_email
    email = params[:email]
    code = params[:code]
    token = VerificationToken.find_by(context: "email-login", sent_to: email, code: code, used: false)

    raise AppError.new("Invalid Email Or Code") unless token
    raise AppError.new("Code Expired") if DateTime.now > token.expires_at

    token.update(used: true)

    user = User.find_or_create_by(email: email)
    render json: { result: "ok", auth_token: user.gen_auth_token, email: params[:email], id: user.id, address_type: "email" }
  end

  def signin_with_password
    phone = params[:phone]
    password = params[:password]
    user = User.find_by(phone: phone)
    if user
      if user.encrypted_password.present?
        raise AuthError.new("Invalid Phone Or Password") unless BCrypt::Password.new(user.encrypted_password) == password
      else
        user.update(encrypted_password: BCrypt::Password.create(password))
      end
      render json: { result: "ok", auth_token: user.gen_auth_token, phone: params[:phone], id: user.id, address_type: "phone" }
    else
      user = User.create(phone: phone, encrypted_password: BCrypt::Password.create(password))
      render json: { result: "ok", auth_token: user.gen_auth_token, phone: params[:phone], id: user.id, address_type: "phone" }
    end
  end

  def set_handle
    user = User.find_by(id: params[:id])
    raise AppError.new("User Not Found") unless user
    raise AppError.new("Invalid Auth Token") unless user == current_user

    handle = params[:handle].to_s
    validate_handle_format!(handle)

    if user.handle.blank?
      assert_handle_available!(handle)
      user.update!(handle: handle)
    else
      raise AppError.new("handle unchanged") if user.handle == handle
      unless user.can_rename?
        next_at = user.next_rename_at.utc.strftime("%Y-%m-%d %H:%M UTC")
        raise AppError.new("Cannot rename handle within 30 days. Next available at: #{next_at}")
      end

      assert_handle_available!(handle, exclude_user_id: user.id)
      old_handle = user.handle

      User.transaction do
        user.handle_aliases.active.find_by(alias: handle)&.destroy!
        HandleAlias.where(alias: old_handle).where("expires_at <= ?", Time.current).delete_all
        user.handle_aliases.create!(alias: old_handle, expires_at: Time.current + User::ALIAS_RETENTION)
        user.update!(handle: handle, handle_changed_at: Time.current)
      end
    end

    render json: { result: "ok" }
  end

  def set_image_url
    user = User.find_by(id: params[:id])
    raise AppError.new("User Not Found") unless user
    raise AppError.new("Invalid Auth Token") unless user == current_user

    user.update(image_url: params[:image_url])
    render json: { result: "ok" }
  end

  def get_by_handle
    query = params[:handle].to_s
    renamed_from = nil

    user = User.find_by(handle: query)
    unless user
      alias_record = HandleAlias.active.find_by(alias: query)
      if alias_record
        user = alias_record.user
        renamed_from = query
      else
        user = User.find_by(phone: query) ||
               User.where("LOWER(evm_chain_address) = ?", query.downcase).first ||
               User.where("LOWER(evm_chain_active_key) = ?", query.downcase).first
      end
    end
    raise AppError.new("User Not Found") unless user

    json = user.as_json(only: [:id, :handle, :phone, :image_url, :evm_chain_address, :evm_chain_active_key, :can_send_badge])
    json["renamed_from"] = renamed_from if renamed_from
    render json: json
  end

  def get_user
    user = User.find_by(id: params[:id])
    raise AppError.new("User Not Found") unless user

    render json: user.as_json(only: [:id, :handle, :email, :phone, :image_url, :evm_chain_address, :evm_chain_active_key, :remaining_gas_credits, :total_used_gas_credits, :can_send_badge])
  end

  def get_me
    user = current_user
    raise AppError.new("User Not Found") unless user

    json = user.as_json(only: [:id, :handle, :email, :phone, :image_url, :evm_chain_address, :evm_chain_active_key, :remaining_gas_credits, :total_used_gas_credits, :encrypted_keys, :can_send_badge, :handle_changed_at])
    json["next_rename_at"] = user.next_rename_at&.iso8601
    render json: json
  end

  # POST /logout
  # 吊销**当前这一个** token（不是该用户的全部 —— 别的设备不该被登出）。
  #
  # 在此之前登出只是前端删掉本地 cookie，服务端那条记录还在、还有效：
  # 谁抄走过那个 token，用户点多少次「退出」都不影响他继续用。
  def logout
    token = current_auth_token
    raise AuthError.new("Unauthorized") unless token

    token.revoke!
    render json: { result: "ok" }
  end

  # POST /logout_all
  # 吊销该用户的全部 token —— 「我的账号可能被盗了」时用。
  def logout_all
    user = current_user
    raise AuthError.new("Unauthorized") unless user

    count = user.auth_tokens.usable.update_all(disabled: true, updated_at: Time.current)
    render json: { result: "ok", revoked: count }
  end

  def remaining_free_transactions
    user = current_user
    raise AppError.new("User Not Found") unless user

    render json: { result: "ok", remaining_free_transactions: (20 - user.transaction_count) }
  end

  def get_encrypted_keys
    user = User.find_by(id: params[:id])
    raise AppError.new("User Not Found") unless user
    raise AppError.new("Invalid Auth Token") unless user == current_user

    render json: { result: "ok", encrypted_keys: user.encrypted_keys }
  end

  def set_encrypted_keys
    user = User.find_by(id: params[:id])
    raise AppError.new("User Not Found") unless user
    raise AppError.new("Invalid Auth Token") unless user == current_user

    user.update(encrypted_keys: params[:encrypted_keys], evm_chain_address: params[:evm_chain_address], evm_chain_active_key: params[:evm_chain_active_key])
    render json: { result: "ok" }
  end

  def set_evm_chain_address
    user = User.find_by(id: params[:id])
    raise AppError.new("User Not Found") unless user
    raise AppError.new("Invalid Auth Token") unless user == current_user

    user.update(evm_chain_address: params[:evm_chain_address], evm_chain_active_key: params[:evm_chain_active_key])
    render json: { result: "ok" }
  end

  def get_transactions
    user = current_user
    raise AppError.new("User Not Found") unless user

    txes = Transaction.where(user_id: user.id).or(Transaction.where(sender_address: user.evm_chain_address)).or(Transaction.where(receiver_address: user.evm_chain_address))

    if params[:txhashes]
      txes = txes.where(tx_hash: params[:txhashes].split(','))
    end

    if params[:metadata]
      txes = txes.where(metadata: params[:metadata])
    end

    render json: { result: "ok", transactions: txes.as_json(only: [:id, :tx_hash, :gas_used, :status, :chain, :data, :memo, :sender_note, :receiver_note, :receiver_address, :sender_address, :created_at, :metadata, :extra], methods: [:sender_handle, :receiver_handle]) }

  end

  def add_transaction
    user = current_user
    raise AppError.new("User Not Found") unless user

    transaction = user.transactions.create(tx_hash: params[:tx_hash], gas_used: params[:gas_used], status: params[:status], chain: params[:chain], data: params[:data], memo: params[:memo], sender_note: params[:sender_note], receiver_address: params[:receiver_address], sender_address: params[:sender_address], metadata: params[:metadata], extra: params[:extra])
    user.update(transaction_count: user.transaction_count + 1)
    render json: { result: "ok" }
  end

  def add_transaction_with_gas_credits
    # raise AppError.new("ADMIN ONLY") unless params[:ADMIN_KEY] == ENV["ADMIN_KEY"]
    # user = User.find_by(id: params[:id])
    user = current_user
    raise AppError.new("User Not Found") unless user

    transaction = user.transactions.create(tx_hash: params[:tx_hash], gas_used: params[:gas_used], status: params[:status], chain: params[:chain], data: params[:data], memo: params[:memo], sender_note: params[:sender_note], receiver_address: params[:receiver_address], sender_address: params[:sender_address], metadata: params[:metadata], extra: params[:extra])
    user.increment!(:total_used_gas_credits, params[:gas_used].to_i)
    user.update(transaction_count: user.transaction_count + 1)
    render json: { result: "ok" }
  end

  def set_transaction_note
    transaction = Transaction.find_by(id: params[:id])
    raise AppError.new("Transaction Not Found") unless transaction
    raise AppError.new("Invalid Auth Token") unless transaction.user == current_user || transaction.sender_address == current_user.evm_chain_address || transaction.receiver_address == current_user.evm_chain_address

    transaction.update(sender_note: params[:sender_note]) if params[:sender_note].present? && (transaction.user == current_user || transaction.sender_address == current_user.evm_chain_address)
    transaction.update(receiver_note: params[:receiver_note]) if params[:receiver_note].present? && transaction.receiver_address == current_user.evm_chain_address
    render json: { result: "ok" }
  end

  def get_token_classes
    render json: { result: "ok", token_classes: TokenClass.order(position: :desc).all }
  end

  def add_token_class
    user = current_user
    raise AppError.new("User Not Found") unless user
    TokenClass.create(
      token_type: params[:token_type], chain: params[:chain], chain_id: params[:chain_id], address: params[:address],
      name: params[:name], symbol: params[:symbol], decimals: params[:decimals], image_url: params[:image_url],
      publisher: user.id, publisher_address: params[:publisher_address], position: params[:position], description: params[:description])
    render json: { result: "ok" }
  end

  def add_wallet
    user = current_user
    raise AppError.new("User Not Found") unless user

    wallet = user.wallets.create(name: params[:name], wallet_type: params[:wallet_type], chain: params[:chain], evm_chain_address: params[:evm_chain_address], evm_chain_active_key: params[:evm_chain_active_key], encrypted_keys: params[:encrypted_keys], format: params[:format])
    render json: { result: "ok", wallet: wallet.as_json(only: [:id, :name, :wallet_type, :chain, :evm_chain_address, :evm_chain_active_key, :encrypted_keys, :format]) }
  end

  def get_wallets
    user = current_user
    raise AppError.new("User Not Found") unless user

    render json: { result: "ok", wallets: user.wallets.as_json(only: [:id, :name, :wallet_type, :chain, :evm_chain_address, :evm_chain_active_key, :encrypted_keys, :format]) }
  end

  def remove_wallet
    user = current_user
    raise AppError.new("User Not Found") unless user

    wallet = user.wallets.find_by(id: params[:id])
    raise AppError.new("Wallet Not Found") unless wallet

    wallet.destroy
    render json: { result: "ok" }
  end

  def set_contacts
    user = User.find_by(id: params[:id])
    raise AppError.new("User Not Found") unless user
    raise AppError.new("Invalid Auth Token") unless user == current_user

    user.update(contact_list: params[:contact_list])
    render json: { result: "ok" }
  end

  def get_contacts
    user = User.find_by(id: params[:id])
    raise AppError.new("User Not Found") unless user
    render json: { result: "ok", contacts: user.contact_list }
  end

  private

  def validate_handle_format!(handle)
    raise AppError.new("handle can not be empty") if handle.blank?
    raise AppError.new("handle must be at least 6 characters") if handle.length < 6
    raise AppError.new("handle cannot exceed 30 characters") if handle.length > 30
    raise AppError.new("handle can only contain letters, numbers, underscores and hyphens") unless handle.match?(/\A[a-zA-Z0-9_-]+\z/)
    raise AppError.new("handle can not be numeric") if handle.match?(/\A\d+\z/)
  end

  def assert_handle_available!(handle, exclude_user_id: nil)
    existing = User.find_by(handle: handle)
    raise AppError.new("handle already exists") if existing && existing.id != exclude_user_id

    alias_record = HandleAlias.active.find_by(alias: handle)
    return unless alias_record
    return if exclude_user_id && alias_record.user_id == exclude_user_id

    raise AppError.new("handle temporarily unavailable")
  end
end
