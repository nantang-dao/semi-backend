class Wallet < ApplicationRecord
    belongs_to :user
    has_many :transactions
    has_many :wallet_owners, dependent: :destroy
    has_many :multisig_transactions, dependent: :destroy

    before_create :set_tsid_id

    private

    def set_tsid_id
      self.id = Tsid::Generator.new.generate
    end
end
