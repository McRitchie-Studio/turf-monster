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

  # ════════════════════════════════════════════════════════════════════════
  # THE BROADCAST SEAM
  # ════════════════════════════════════════════════════════════════════════
  #
  # One rule, on the model, because TWO controllers broadcast these rows
  # (Admin::PendingTransactionsController and Admin::AuthoritiesController) and
  # the rule decides whether treasury money can move twice. Two copies of it is
  # how the two paths drift.
  #
  # ── WHY `pending?` IS NOT ENOUGH ───────────────────────────────────────────
  #
  # A broadcast is a state READ, a simulation, a send, and then a verification
  # that costs one RPC call per claimed signer. `raise unless @tx.pending?` is a
  # read, not a claim: two requests can both pass it, both reach
  # `simulate_and_broadcast`, and both put a wire on the chain. Each rebuild
  # mints fresh bytes, so the two wires carry different blockhashes and
  # different signatures — two settlements land, and only one is ever
  # reconciled. A double-click is enough; no attacker is required.
  #
  # ── AND WHY NOT `with_lock` ────────────────────────────────────────────────
  #
  # `with_lock` would hold an open transaction and a row lock across two RPC
  # round trips and a signing step, on a connection pool the whole app shares.
  # A single conditional UPDATE gets the same exclusion: the database decides,
  # exactly one caller is told it won, and the lock lives only for the duration
  # of that statement.

  # WIN THE RIGHT TO BROADCAST. True to exactly one caller; false to everyone
  # who arrives after. Reloads either way, so a refusal can name the state the
  # row is ACTUALLY in.
  def claim_for_broadcast!
    won = self.class.where(id: id, status: "pending")
                    .update_all(status: "submitted", updated_at: Time.current) == 1
    reload
    won
  end

  # THE WIRE LANDED — record it, NOW.
  #
  # `update_columns` on purpose: no validation and no callback may stand between
  # a transaction that has left the server and the record of it. This is called
  # the instant `simulate_and_broadcast` returns, BEFORE verification, so a
  # flaked verify becomes an alert on a recorded transaction instead of the
  # absence of a record.
  def record_broadcast!(signature)
    update_columns(tx_signature: signature, status: "submitted", updated_at: Time.current)
  end

  # GIVE THE CLAIM BACK. Only ever for `Solana::Vault::PreflightRejected` — a
  # failure the vault PROVED happened before any bytes left the server.
  #
  # Guarded on `tx_signature: nil` as a second line: a release can never
  # un-record a broadcast that did happen, even if a caller reaches for it on
  # the wrong error.
  def release_broadcast_claim!
    self.class.where(id: id, status: "submitted", tx_signature: nil)
              .update_all(status: "pending", updated_at: Time.current)
    reload
  end

  # BROADCAST, ANSWER LOST. The claim was taken and no signature came back, so
  # the wire may or may not be on the chain. This is the one state where a
  # re-send is forbidden AND a signature may still be recorded out of band —
  # the operator finds it on chain and posts it to #confirm, which VERIFIES it
  # before writing. It is the reconciliation door, and it is why closing the
  # double-send window does not strand the row.
  def awaiting_reconciliation?
    status == "submitted" && tx_signature.blank?
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
