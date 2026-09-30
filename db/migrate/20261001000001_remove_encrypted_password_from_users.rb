# 密码登录已下线。存量值是 bcrypt(sha256(6 位 PIN))，而同一个 PIN 也是 keystore 的口令，
# 留在库里等于给离线破解 keystore 递钥匙，所以连列一起删掉，不可恢复。
#
# 滚动部署窗口：旧容器的 User 仍缓存着这一列，load_defaults 8.0 下 INSERT 会带上它，
# 所以新旧容器并存的那一小段时间里，落到旧容器上的「新用户注册」会 500。已有用户
# 登录只做 UPDATE（只写改动的字段），不受影响。按现有注册量这个窗口可以接受。
class RemoveEncryptedPasswordFromUsers < ActiveRecord::Migration[8.0]
  def change
    remove_column :users, :encrypted_password, :string
  end
end
