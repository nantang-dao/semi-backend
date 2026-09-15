class Wallet < ApplicationRecord
    belongs_to :user
    has_many :transactions
    has_many :wallet_owners, dependent: :destroy
    has_many :multisig_transactions, dependent: :destroy

    before_create :set_tsid_id

    # 多签钱包可以同时存在的链。同一个 Safe 地址在组内每条链上各一行 wallet，
    # owner / 门限 / 队列 / nonce 都挂在行上，按链隔离。测试网单独成组，
    # 不会和主网的行关联。
    MULTISIG_CHAIN_GROUPS = [
      [ 10, 42161, 1 ],
      [ 11155111 ]
    ].freeze

    def self.multisig_chain_group(chain_id)
      MULTISIG_CHAIN_GROUPS.find { |group| group.include?(chain_id.to_i) }
    end

    # 按地址找多签行，忽略大小写：老数据的地址大小写没有统一过，也不去改它
    def self.multisig_at(address)
      where(wallet_type: "multisig").where("LOWER(evm_chain_address) = ?", address.to_s.downcase)
    end

    def self.multisig_chain_supported?(chain_id)
      multisig_chain_group(chain_id).present?
    end

    def multisig_chain_id
      chain_id || chain.to_i
    end

    def multisig_chain_group_key
      self.class.multisig_chain_group(multisig_chain_id)
    end

    # 同一 Safe 地址、同一链组、其他链上的多签钱包行
    def multisig_siblings
      group = self.class.multisig_chain_group(multisig_chain_id) || []
      Wallet.multisig_at(evm_chain_address).where(chain_id: group)
            .where.not(id: id)
    end

    def owner_address_list
      wallet_owners.pluck(:owner_address).map { |a| a.to_s.downcase }
    end

    private

    def set_tsid_id
      self.id = Tsid::Generator.new.generate
    end
end
