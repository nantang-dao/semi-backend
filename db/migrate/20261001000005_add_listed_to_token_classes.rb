# 用户加的代币默认只有自己看得到，管理员上架后才进全局列表。
# 现有的代币（生产上 7 个，都是团队加的）全部视为已上架。
class AddListedToTokenClasses < ActiveRecord::Migration[8.0]
  def up
    add_column :token_classes, :listed, :boolean, default: false, null: false
    execute "UPDATE token_classes SET listed = TRUE"
  end

  def down
    remove_column :token_classes, :listed
  end
end
