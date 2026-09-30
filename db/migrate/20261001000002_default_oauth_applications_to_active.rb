# 新建的 OAuth 应用默认就是已上线。原来默认 draft，开发者不知道要去编辑里手动上线，
# 授权时只看到「Application is not active」。
class DefaultOauthApplicationsToActive < ActiveRecord::Migration[8.0]
  def change
    change_column_default :oauth_applications, :status, from: "draft", to: "active"
  end
end
