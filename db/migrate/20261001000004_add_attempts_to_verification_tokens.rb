class AddAttemptsToVerificationTokens < ActiveRecord::Migration[8.0]
  def change
    add_column :verification_tokens, :attempts, :integer, default: 0, null: false
    add_column :verification_tokens, :ip, :string
    add_index :verification_tokens, [ :context, :sent_to, :created_at ]
    add_index :verification_tokens, [ :ip, :created_at ]
  end
end
