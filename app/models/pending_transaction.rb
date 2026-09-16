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
  # Not because it ties up a pooled connection — the connection is checked out
  # for the duration of the request either way, `with_lock` or not. The cost is
  # that `with_lock` opens a TRANSACTION and takes a ROW LOCK, and then holds
  # both across the RPC round trips inside the block: the simulation, the send,
  # and a confirmation poll that is allowed to run for 30 seconds before it
  # gives up. A second request for the same row would BLOCK for the whole of
  # the first one's work and only then discover it had lost — a long stall
  # ending in the same refusal. A single conditional UPDATE gets the identical
  # exclusion and fails the loser FAST: the database decides, exactly one
  # caller is told it won, and the lock lives only for that one statement.
  #
  # ── THE SIGNATURE IS KNOWN BEFORE THE SEND, SO IT IS STAMPED BEFORE THE SEND ─
  #
  # A Solana transaction's signature is the first 64 bytes of its own signed
  # wire. It is a FACT ABOUT THE BYTES, not an answer the RPC gives us — see
  # `Solana::Vault#signature_for_wire`. So the claim stamps it, in the same
  # statement that takes the claim, before anything is sent.
  #
  # That ordering is what keeps a failed broadcast RECOVERABLE. The earlier
  # design stamped the signature from the RPC's reply, so any failure that ate
  # the reply left a claimed row with NO signature and no way to ask the chain
  # what had happened to it — `#rebuild` refused it, `#broadcast` refused it,
  # `#confirm` needed a signature that did not exist, and the only way out was
  # a Rails console. With the signature stamped up front there is always a
  # handle: `#reconcile_broadcast!` asks the chain and the four-way verdict
  # decides. Cdp::OfframpSendJob persists its signature before the send for
  # exactly this reason.
  include OnchainSendVerdict

  # WIN THE RIGHT TO BROADCAST, AND RECORD WHAT IS ABOUT TO GO OUT — one
  # statement, so the row can never be claimed without naming its transaction.
  # True to exactly one caller; false to everyone who arrives after. Reloads
  # either way, so a refusal can name the state the row is ACTUALLY in.
  #
  # `broadcast_at` is stamped here and nowhere else: it is the anchor
  # `#blockhash_lapsed?` measures from, and it must mean "the moment before the
  # wire went out" for the :never_landed verdict to be a proof rather than a
  # guess.
  #
  # RAISES ActiveRecord::RecordNotUnique if `signature` already backs another
  # row (the partial unique index on tx_signature). That is the correct answer
  # and it happens HERE, before the send: the claim is not taken, so nothing is
  # stranded and nothing is broadcast twice.
  def claim_for_broadcast!(signature)
    raise ArgumentError, "a broadcast claim must name the signature it is about to send" if signature.blank?

    won = self.class.where(id: id, status: "pending")
                    .update_all(status: "submitted", tx_signature: signature,
                                broadcast_at: Time.current, updated_at: Time.current) == 1
    reload
    won
  end

  # GIVE THE CLAIM BACK — the one exception to "never rewind".
  #
  # LEGAL ON A PROOF AND NOTHING ELSE. There are exactly two proofs:
  #
  #   1. `Solana::Vault::PreflightRejected` — the simulation refused the wire
  #      or could not be run, so `client.send_transaction` was never called.
  #      Nothing left this server.
  #   2. `#send_verdict` returned :never_landed or :failed — the CHAIN says so.
  #
  # A failure of the SEND is not a proof and never rewinds. See
  # `#reconcile_broadcast!` for why the exception object cannot be read as one.
  #
  # Guarded on the exact signature the caller proved dead, so a rewind can
  # never clear a signature some other request has just stamped, and can never
  # act on a row that has moved on since the caller read it.
  def rewind_broadcast!(signature)
    return false if signature.blank?

    won = self.class.where(id: id, status: "submitted", tx_signature: signature)
                    .update_all(status: "pending", tx_signature: nil, broadcast_at: nil,
                                updated_at: Time.current) == 1
    reload
    won
  end

  # BROADCAST, VERDICT NOT YET IN. The normal post-claim state: the row names
  # its transaction, so `#reconcile_broadcast!` can always ask the chain what
  # happened to it. Never a dead end.
  def awaiting_broadcast_verdict?
    status == "submitted" && tx_signature.present?
  end

  # LEGACY ONLY — a claimed row carrying no signature.
  #
  # `#claim_for_broadcast!` cannot produce this state any more; it stamps the
  # signature in the same statement that takes the claim. It survives for rows
  # claimed by the OLDER code, which stamped from the RPC's reply and therefore
  # left nothing behind when that reply was lost. Those rows have no handle to
  # ask the chain with, so they are still reconciled by hand through `#confirm`
  # (an operator finds the signature on chain and posts it, and it is VERIFIED
  # before it is written).
  def awaiting_reconciliation?
    status == "submitted" && tx_signature.blank?
  end

  # ASK THE CHAIN WHAT HAPPENED, THEN ACT ON THE ANSWER.
  #
  # Takes the row's getSignatureStatuses value — which the caller MUST fetch
  # with `searchTransactionHistory: true` (`Solana::Client#confirm_transaction`
  # does) — and applies `OnchainSendVerdict#send_verdict`:
  #
  #   :landed       — left alone HERE. The caller still owes the OPSEC-010/011
  #                   verification before any DB state flips; this method has
  #                   no cosigner context and must not confirm on its own.
  #   :failed       — landed WITH an on-chain error. Definitive: the treasury
  #                   did not move. Rewound, so the operator can rebuild.
  #                   This is the case Solana::TxVerifier cannot record — it
  #                   refuses anything carrying meta.err — which is why the
  #                   door is here and not on `#confirm`.
  #   :never_landed — absent from a history-searched lookup, past the blockhash
  #                   window. Verified-dead. Rewound.
  #   :ambiguous    — still landable, or the RPC is lagging. NOTHING CHANGES.
  #                   The row stays claimed and un-rebuildable, which is the
  #                   entire point: a rewind here is a double-send.
  #
  # Returns the verdict so the caller can tell the operator what it did.
  def reconcile_broadcast!(status, now: Time.current)
    verdict = send_verdict(status, now: now)

    case verdict
    when :failed
      Rails.logger.warn("[treasury][reconcile] #{slug} tx failed on chain " \
                        "err=#{status['err'].inspect} sig=#{tx_signature} — rewound for a rebuild")
      rewind_broadcast!(tx_signature)
    when :never_landed
      Rails.logger.warn("[treasury][reconcile] #{slug} sig=#{tx_signature} never landed " \
                        "(blockhash window lapsed) — rewound for a rebuild")
      rewind_broadcast!(tx_signature)
    end

    verdict
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
