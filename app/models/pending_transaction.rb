class PendingTransaction < ApplicationRecord
  include Sluggable

  belongs_to :target, polymorphic: true, optional: true

  validates :tx_type, presence: true
  validates :serialized_tx, presence: true
  validates :status, inclusion: { in: %w[pending submitted confirmed expired failed] }

  # Single-use broadcast signatures (Lazarus audit #8 residual). A finalized
  # tx_signature may back at most ONE PendingTransaction — mirrors the
  # entries.onchain_tx_signature guard. allow_nil keeps unbroadcast rows
  # (signature is set only once submitted) unconstrained; the partial unique DB
  # index (20260601000001) is the race-safe backstop, this gives a clean error.
  validates :tx_signature, uniqueness: true, allow_nil: true

  # BL4 (Stage 3 audit) bug fix: name_slug includes `id`, which is nil during
  # Sluggable's before_save. Without intervention, every row got slug "ptx-"
  # → unique index meant only ONE PendingTransaction could exist at a time
  # (treasury blocker). Use tmp-unique slug during INSERT, then overwrite
  # with canonical "ptx-<id>" after_create.
  after_create :update_slug_with_id

  scope :pending, -> { where(status: "pending") }
  scope :confirmed, -> { where(status: "confirmed") }

  # What the operator is actually being asked to sign — `pending` minus the rows
  # marked stale. This is the ONLY count the Signatures badge should ever show:
  # `pending` alone was 11 on production the day the badge was built, and 10 of
  # those were dead `enter_contest` rows from June and July. A badge that cries
  # wolf on its first day never gets looked at again.
  scope :awaiting_signature, -> { pending.where(stale: false) }

  def name_slug
    id ? "ptx-#{id}" : "ptx-tmp-#{SecureRandom.hex(8)}"
  end

  def parsed_metadata
    metadata.present? ? JSON.parse(metadata) : {}
  end

  def pending?
    status == "pending"
  end

  def confirmed?
    status == "confirmed"
  end

  # Every vault signer recorded against this transaction, oldest schema first.
  #
  # FALLS BACK TO THE SINGULAR COLUMN rather than returning empty. Rows
  # confirmed before `cosigner_addresses` existed carry their one signer in
  # `cosigner_address`, and a reader that returned `[]` for them would report a
  # settled payout as authorised by nobody — a worse answer than the partial
  # one the old schema could give. The fallback is not a backfill: it is how
  # the two eras are read through one method.
  def all_cosigners
    recorded = Array(cosigner_addresses).reject(&:blank?)
    return recorded if recorded.any?

    [cosigner_address].compact.reject(&:blank?)
  end

  # How many vault signatures this transaction's action needs ON CHAIN, or nil
  # when the type is not one this app cosigns. Nil rather than a guess: a number
  # here that is too low is exactly the defect that took six treasury paths down.
  #
  # THIS IS NOT THE NUMBER A UI SHOULD SIZE A FORM FROM. It is what the PROGRAM
  # demands, and it is deliberately governance-INDEPENDENT — three is three
  # whether or not this boot speaks v0.26. What a form needs is how many slots
  # THIS BUILD will actually reserve, which is `extra_cosigners_needed` below.
  # Sizing a control from `required_signatures - 2` is how the page came to ask
  # for a wallet the server then refused.
  def required_signatures
    Solana::CosignPlan.new(tx_type: tx_type).required_signatures
  rescue Solana::CosignPlan::InvalidCosignerError, Solana::Governance::UnknownActionError
    nil
  end

  # How many EXTRA cosigner wallets the operator must supply for this row —
  # THE SAME METHOD THE SERVER SIZES ITS VALIDATION FROM.
  #
  # ONE SOURCE OF TRUTH, ON PURPOSE. When the view derived this number
  # separately it disagreed with the server on a v0.25 boot: the page rendered a
  # second-wallet control (three signatures minus two named) while
  # `CosignPlan#validate_extras!` sized `needed` at zero, so the operator picked
  # a wallet and `#rebuild` refused it 422. That is the DEPLOYED shape — it
  # would have broken the treasury page before v0.26 ever landed. Two
  # derivations of one number is the defect class this whole change exists to
  # remove, so the view asks this and the server asks the plan, and they are the
  # same call.
  def extra_cosigners_needed
    Solana::CosignPlan.new(tx_type: tx_type).extra_cosigners_needed
  rescue Solana::CosignPlan::InvalidCosignerError, Solana::Governance::UnknownActionError
    0
  end

  private

  def update_slug_with_id
    update_column(:slug, "ptx-#{id}")
  end
end
