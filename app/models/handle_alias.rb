class HandleAlias < ApplicationRecord
  self.table_name = "handle_aliases"

  belongs_to :user

  scope :active, -> { where("expires_at > ?", Time.current) }
end
