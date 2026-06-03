class MultisigSignature < ApplicationRecord
  self.primary_key = nil

  belongs_to :multisig_transaction

  validates :signer_address, presence: true
  validates :signature, presence: true
  validates :signer_address, uniqueness: { scope: :multisig_transaction_id, case_sensitive: false }

  before_save :normalize_address

  private

  def normalize_address
    self.signer_address = signer_address.downcase if signer_address
  end
end
