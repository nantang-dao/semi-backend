class SafeWallet < ApplicationRecord
  belongs_to :creator, class_name: "User"
  has_many :safe_owners, dependent: :destroy
  has_many :safe_transactions, dependent: :destroy

  STATUSES = %w[active archived].freeze

  validates :name, presence: true
  validates :chain_id, presence: true
  validates :threshold, presence: true, numericality: { greater_than: 0 }
  validates :status, inclusion: { in: STATUSES }

  before_create :set_tsid_id

  def active_owners
    safe_owners.where(removed_at: nil)
  end

  def threshold_valid?
    threshold <= active_owners.count
  end

  private

  def set_tsid_id
    self.id = Tsid::Generator.new.generate
  end
end
