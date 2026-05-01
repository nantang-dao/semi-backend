module SemiOAuth
  def self.private_key
    @private_key ||= begin
      pem = Rails.application.credentials.dig(:oauth, :rsa_private_key) ||
            ENV["OAUTH_RSA_PRIVATE_KEY"]
      OpenSSL::PKey::RSA.new(pem) if pem.present?
    rescue OpenSSL::PKey::RSAError => e
      Rails.logger.warn("SemiOAuth: invalid RSA key — #{e.message}")
      nil
    end
  end

  def self.public_key
    private_key&.public_key
  end

  def self.key_id
    return nil unless public_key
    @key_id ||= Digest::SHA256.hexdigest(public_key.to_der)[0..7]
  end
end
