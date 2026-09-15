# One row per Coinbase CDP hosted-widget session (onramp = buy USDC into the
# user's wallet, offramp = sell USDC to fiat). Created BEFORE the session token
# is minted so partner_user_ref ("tm-<user_id>-<id>") exists to correlate the
# widget session with the Transaction Status API + (phase 2) webhooks.
#
# Two status fields, deliberately separate:
#   - status      — OUR local lifecycle (see STATUSES below)
#   - cdp_status  — the raw CDP status string, stored verbatim (the API enum
#                   conflicts between doc pages — handle unknown values
#                   defensively, never case-exhaustively)
#
# coinbase_transaction_id is the idempotency key for poll-job/webhook upserts.
# See docs/CDP_RAMP_INTEGRATION.md §9.
class CdpRampTransaction < ApplicationRecord
  # partnerUserRef must be < 50 chars in the hosted URLs + status APIs.
  PARTNER_USER_REF_MAX = 49

  # Statuses BEFORE a CDP transaction exists for this session — nothing has
  # materialized Coinbase-side, so an expired session in one of these is safe
  # to expire locally (no funds can be in flight).
  PRE_CDP_STATUSES = %w[initiated token_minted returned].freeze
  TERMINAL_STATUSES = %w[success failed expired abandoned].freeze

  belongs_to :user

  # Local lifecycle:
  #   initiated    — row created, nothing minted yet
  #   token_minted — session token minted, hosted URL handed to the client
  #   returned     — user hit our redirectUrl (UX signal only — NEVER confirmation)
  #   cdp_created  — offramp: CDP transaction exists (TRANSACTION_STATUS_CREATED);
  #                  gates our USDC send within the 30-minute window
  #   sending      — offramp: our USDC transfer to to_address is in flight
  #   sent         — offramp: sent_signature recorded, awaiting CDP settlement
  #   success      — terminal: CDP reports the ramp completed
  #   failed       — terminal: CDP reports failure (incl. late offramp sends)
  #   expired      — terminal: session/cashout window lapsed before completion
  #   abandoned    — terminal: user never came back (stale sweep)
  enum :status, {
    initiated:    "initiated",
    token_minted: "token_minted",
    returned:     "returned",
    cdp_created:  "cdp_created",
    sending:      "sending",
    sent:         "sent",
    success:      "success",
    failed:       "failed",
    expired:      "expired",
    abandoned:    "abandoned"
  }, default: "initiated"

  enum :direction, { onramp: "onramp", offramp: "offramp" }

  # web2 = managed wallet (server can sign the offramp send),
  # web3 = Phantom (client signs).
  enum :wallet_mode, { web2: "web2", web3: "web3" }, prefix: :wallet

  validates :direction, presence: true
  validates :status, presence: true
  validates :wallet_address, presence: true
  validates :wallet_mode, presence: true
  validates :asset, presence: true
  validates :network, presence: true
  validates :partner_user_ref,
            uniqueness: true,
            length: { maximum: PARTNER_USER_REF_MAX },
            allow_nil: true
  validates :coinbase_transaction_id, uniqueness: true, allow_nil: true

  # Needs the row id, so it can't be a before_validation (same pattern as
  # Entry's id-bearing slug).
  after_create :assign_partner_user_ref

  scope :recent, -> { order(created_at: :desc) }
  scope :active, -> { where.not(status: TERMINAL_STATUSES) }

  def terminal?
    TERMINAL_STATUSES.include?(status)
  end

  def pre_cdp?
    PRE_CDP_STATUSES.include?(status)
  end

  def sell_amount
    return nil if sell_amount_value.nil?
    BigDecimal(sell_amount_value.to_s)
  end

  # ErrorLog target compatibility — rescue_and_log / the poll jobs set
  # target_name = target.slug. No slug COLUMN (the correlation key doubles as
  # the identifier); this method preserves the shared ErrorLog target contract.
  def slug
    partner_user_ref || "cdp-ramp-#{id}"
  end

  # ── State transitions — server-side only, never raw status writes ─────────
  # Each guard makes the transition idempotent and refuses to downgrade a
  # further-along row (a stale poll/return hit can't rewind the lifecycle).
  # All return false on a refused transition instead of raising.

  # Session token minted + hosted URL handed to the client.
  def mark_token_minted!
    return false unless initiated?
    update!(status: :token_minted)
  end

  # Redirect-page hit. UX signal ONLY — never confirmation (the redirect
  # carries no documented params). Stamps returned_at once; advances status
  # only when nothing further has already happened.
  def mark_returned!
    return false if terminal?
    attrs = {}
    attrs[:returned_at] = Time.current if returned_at.blank?
    attrs[:status] = :returned if initiated? || token_minted?
    update!(attrs) if attrs.any?
    true
  end

  # Offramp: the CDP transaction exists (TRANSACTION_STATUS_CREATED) — gates
  # our USDC send within the 30-minute cashout window.
  def mark_cdp_created!
    return false unless pre_cdp?
    update!(status: :cdp_created)
  end

  # Offramp send (managed mode): the signature is persisted in the SAME write
  # that flips the status — i.e. durably recorded BEFORE any broadcast attempt
  # completes. That is the verify-before-retry anchor: a crash/timeout between
  # broadcast and confirmation leaves the signature on the row so the next run
  # checks it on-chain instead of blind-resending (Cdp::OfframpSendJob).
  #
  # broadcast_at records the actual broadcast-attempt time — the send job's
  # blockhash-lapse verdict anchors HERE, never on confirmed_at (the user's
  # confirmation click can legally precede the broadcast by minutes).
  def mark_sending!(signature)
    return false if signature.blank?
    return true if sending? && sent_signature == signature
    return false unless cdp_created?
    update!(status: :sending, sent_signature: signature, broadcast_at: Time.current)
  end

  # Offramp send confirmed on-chain (managed mode, from :sending) or a
  # client-reported + server-verified Phantom send (from :cdp_created — the
  # client broadcast, so there is no local :sending step). Refuses to
  # overwrite a DIFFERENT already-recorded signature.
  def mark_sent!(signature = nil)
    return true if sent? && (signature.blank? || sent_signature == signature)
    return false unless cdp_created? || sending?
    return false if signature.present? && sent_signature.present? && sent_signature != signature
    attrs = { status: :sent }
    attrs[:sent_signature] = signature if signature.present?
    update!(attrs)
  end

  # A persisted signature still absent from getSignatureStatuses (searched with
  # searchTransactionHistory) this long after the BROADCAST ATTEMPT
  # (broadcast_at, stamped by #mark_sending!) can never land.
  #
  # Lives HERE rather than on Cdp::OfframpSendJob because two callers now need
  # the same answer — the job's verify-before-retry path and the Phantom
  # cash-out cosign endpoint — and this is the number that decides whether a
  # rewind is verified-dead or a double-send.
  BLOCKHASH_LAPSE = 5.minutes

  # THE FOUR-WAY VERDICT on a recorded send, given its getSignatureStatuses row
  # (`confirm_transaction(sig).dig("value", 0)`) and this row's broadcast_at.
  #
  #   :landed        — confirmed/finalized with no err. The money MOVED.
  #   :failed        — an on-chain err. Definitive: the funds did NOT move.
  #   :never_landed  — absent from a HISTORY-SEARCHED lookup, long past the
  #                    blockhash window. Verified-dead, not merely unseen.
  #   :ambiguous     — anything else, and the ONLY safe answer to most of them.
  #
  # WHY THIS IS ONE METHOD AND NOT TWO COPIES. Both callers rewind a row on
  # this verdict, and a rewind is what lets a SECOND full-amount transfer be
  # built. Getting :ambiguous wrong in either copy double-sends a player's
  # USDC — so there is one implementation, and both callers read it.
  #
  # THE TRAP IT EXISTS TO CLOSE: "no row" is NOT "never landed". An absent
  # status also means in-flight and not-yet-indexed, and it means that for the
  # whole blockhash window. Only the age of the BROADCAST separates the two,
  # which is why this takes broadcast_at and never confirmed_at — the broadcast
  # can legally trail the user's confirmation click by minutes, so a
  # confirmed_at anchor can declare a just-broadcast tx dead while it is still
  # perfectly landable.
  #
  # It also REQUIRES a history-searched status. A plain getTransaction at
  # `confirmed` returns nothing for a tx that is merely unindexed, which reads
  # as :never_landed here and is exactly the double-send this guards.
  def send_verdict(status, now: Time.current)
    if status && status["err"].nil? && %w[confirmed finalized].include?(status["confirmationStatus"])
      :landed
    elsif status && status["err"]
      :failed
    elsif status.nil? && blockhash_lapsed?(now: now)
      :never_landed
    else
      :ambiguous
    end
  end

  # No anchor (shouldn't happen — #mark_sending! always stamps broadcast_at) is
  # AMBIGUOUS, never verified-dead.
  def blockhash_lapsed?(now: Time.current)
    broadcast_at.present? && now > broadcast_at + BLOCKHASH_LAPSE
  end

  # DELIBERATE rewind — the one exception to "never rewind", allowed only
  # after an on-chain verification proved the broadcast definitively failed
  # (getSignatureStatuses returned an err, or the blockhash window lapsed with
  # the signature never appearing). Clears the dead signature AND its
  # broadcast_at anchor so a fresh, fully re-guarded attempt can build a new
  # transaction with its own broadcast timestamp.
  def reset_failed_send!
    return false unless sending?
    update!(status: :cdp_created, sent_signature: nil, broadcast_at: nil)
  end

  def mark_success!
    return false if terminal?
    update!(status: :success)
  end

  def mark_failed!
    return false if terminal?
    update!(status: :failed)
  end

  def mark_expired!
    return false if terminal?
    update!(status: :expired)
  end

  private

  def assign_partner_user_ref
    return if partner_user_ref.present?
    update_column(:partner_user_ref, "tm-#{user_id}-#{id}")
  end
end
