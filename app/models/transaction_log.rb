class TransactionLog < ApplicationRecord
  after_create :update_slug_with_id

  belongs_to :user
  belongs_to :source, polymorphic: true, optional: true

  validates :transaction_type, presence: true
  validates :amount_cents, presence: true, numericality: { greater_than: 0 }
  validates :direction, presence: true, inclusion: { in: %w[credit debit] }
  # `needs_review` is the distinct terminal state Deposits::OnchainReconciler
  # assigns to a stranded deposit whose on-chain transfer it could NOT confirm
  # landed. It is never re-transferred; a human resolves it. Kept out of the
  # `completed`/`failed` buckets so a stranded money-path row stays loud.
  validates :status, presence: true, inclusion: { in: %w[completed pending failed approved needs_review] }

  scope :credits, -> { where(direction: "credit") }
  scope :debits, -> { where(direction: "debit") }
  scope :pending, -> { where(status: "pending") }
  scope :completed, -> { where(status: "completed") }
  scope :needs_review, -> { where(status: "needs_review") }
  scope :by_type, ->(type) { where(transaction_type: type) }

  TYPES = %w[deposit withdrawal entry_fee payout admin_credit faucet token_purchase].freeze

  # OPSEC-022: stripe_session_id + moonpay_tx_id columns have DB-level
  # partial unique indexes. Callers passing these get idempotency enforced
  # at the row-insert level instead of via JSONB scan + TOCTOU.
  # Duplicate inserts raise ActiveRecord::RecordNotUnique.
  def self.record!(user:, type:, amount_cents:, direction:, source: nil, description: nil, status: "completed", onchain_tx: nil, metadata: {}, stripe_session_id: nil, moonpay_tx_id: nil)
    create!(
      user: user,
      transaction_type: type,
      amount_cents: amount_cents,
      direction: direction,
      balance_after_cents: nil,
      source: source,
      source_name: source&.slug,
      description: description,
      status: status,
      onchain_tx: onchain_tx,
      metadata: metadata,
      stripe_session_id: stripe_session_id,
      moonpay_tx_id: moonpay_tx_id
    )
  end

  def credit?
    direction == "credit"
  end

  def debit?
    direction == "debit"
  end

  def amount_dollars
    amount_cents / 100.0
  end

  def balance_after_dollars
    return nil unless balance_after_cents
    balance_after_cents / 100.0
  end

  private

  def update_slug_with_id
    update_column(:slug, name_slug)
  end

  public

  def to_param
    slug
  end

  def name_slug
    "txn-#{id}"
  end
end
