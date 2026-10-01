# 生产环境缺 KEYSTORE_SERVER_SECRET 就别启动：否则 v2 用户解锁时才 500。启动失败时 ginger
# 的健康检查不通过，旧容器继续服务。见 app/services/keystore_vault.rb。
Rails.application.config.after_initialize do
  KeystoreVault.server_secret if Rails.env.production?
end
