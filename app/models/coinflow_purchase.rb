# Audit log for Coinflow entry-token purchases — the Coinflow-rails sibling of
# StripePurchase / PaypalPurchase. The minted tokens live on-chain as
# EntryTokenAccount PDAs in turf-vault; this row maps a Coinflow hosted-checkout
# settlement to its on-chain mint TX(s) for chargeback / refund forensics.
#
# Pack definitions stay on StripePurchase::PACKS — single source of truth for
# every provider (see StripePurchase.pack). "Buy 1 entry" is pack "single"
# (quantity 1, price_cents 19_00).
#
# Status walk: pending → captured → minted, with refunded / failed terminals.
# "captured" is the post-settlement, pre-mint state — Coinflow's `Settled`
# webhook cleared for the exact pack amount but the on-chain mint hasn't
# finished yet.
#
# Money model note: Coinflow is CENTS-native (no decimal strings like PayPal).
# The amount we validate is the SUBTOTAL we set server-side (price_cents), NOT
# the buyer-facing total (subtotal + Coinflow fees) — total varies with fees
# and is not an invariant we control.
class CoinflowPurchase < ApplicationRecord
  include Sluggable
  include MintablePurchase

  STATUSES = %w[pending captured minted refunded failed].freeze

  belongs_to :user

  validates :coinflow_reference, uniqueness: true, allow_nil: true
  validates :coinflow_payment_id, uniqueness: true, allow_nil: true
  validates :pack_id, presence: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :price_cents, numericality: { greater_than: 0 }
  validates :status, inclusion: { in: STATUSES }

  scope :minted,        -> { where(status: "minted") }
  scope :pending,       -> { where(status: "pending") }
  scope :captured,      -> { where(status: "captured") }
  scope :refunded,      -> { where(status: "refunded") }
  scope :for_reference, ->(reference) { where(coinflow_reference: reference) }

  # Tier-3 settlement resolution — the ONLY path a real `Settled` event takes,
  # because Coinflow's payload carries no reference field (see
  # Webhooks::CoinflowController#purchase_for_event). Given the buyer and the
  # settled amount, pick their OLDEST pending row AT THAT PRICE.
  #
  # The price scope is load-bearing, not defensive. Oldest-first consumption is
  # only fungible among rows that cost the same: while the Coinflow rail sold
  # nothing but the $19 single, any pending row was as good as any other. Once
  # the buy page offers single AND trio (and the Add Funds hub / buy-entry modal
  # still open $19 rows), an abandoned $19 row would otherwise absorb a later
  # $49 trio settlement — capture_matches? then fails on the amount and the
  # settlement is REJECTED, so the buyer pays $49 and receives nothing.
  # Scoping by price keeps oldest-first fungibility WITHIN a price class and
  # makes the cross-pack hijack unrepresentable.
  #
  # Fails closed on an unreadable amount: with no trustworthy price there is no
  # safe row to pick, and guessing is precisely the bug above.
  def self.pending_for_settlement(user_id:, cents:)
    cents = cents.to_i
    return nil unless cents.positive?

    where(user_id: user_id, status: "pending", price_cents: cents).order(:created_at).first
  end

  # Atomic pending → captured transition — the exactly-once fulfillment gate.
  # A Coinflow `Settled` webhook can be redelivered (webhooks may arrive more
  # than once); the single-row `UPDATE ... WHERE status = 'pending'` guarantees
  # exactly one caller wins (returns true) and enqueues the mint, stamping the
  # settlement payment id atomically. TokenPurchaseJob's source_ref idempotency
  # (OPSEC-009) backstops any double-enqueue regardless.
  def begin_fulfillment!(capture_id:)
    won = self.class.where(id: id, status: "pending").update_all(
      status: "captured",
      coinflow_payment_id: capture_id,
      captured_at: Time.current,
      updated_at: Time.current
    ) == 1
    reload
    won
  end

  # Validates a Coinflow settlement payload against this purchase before
  # anything mints — never trust a client-reported amount. Coinflow reports
  # money as integer cents under `subtotal` / `fees` / `total`. We match the
  # SUBTOTAL (the amount we set at checkout-link creation) against the pack
  # price, in USD. Matching `total` would be wrong: total = subtotal + Coinflow
  # fees, so it never equals the pack price.
  #
  # Fail-closed on a malformed payload: if `subtotal` is anything but the
  # documented `{cents:, currency:}` hash (e.g. a bare integer), return false
  # (no mint) rather than let `.dig` raise TypeError up into a webhook 500.
  def capture_matches?(payload)
    return false unless payload.present?

    subtotal = payload["subtotal"]
    return false unless subtotal.is_a?(Hash)

    subtotal["currency"] == "USD" &&
      subtotal["cents"].to_i == expected_amount_cents
  end

  # Coinflow amounts are integer cents (unlike PayPal's "19.00" decimal string).
  def expected_amount_cents
    price_cents
  end

  private

  def name_slug
    # No stable external id at create time (Coinflow's hosted-checkout link is
    # opaque and returns no order id we key on), so the slug is pure entropy.
    # It IS the coinflow_reference we hand Coinflow and match on settlement.
    "coinflow_#{SecureRandom.hex(6)}"
  end

  # NEUTRALIZE Sluggable's per-save re-derive (same trap PaypalPurchase#set_slug
  # documents): the engine's `before_save :set_slug` reassigns `slug =
  # name_slug` on EVERY save, and name_slug here is fresh entropy each call —
  # without this override the slug (and thus the coinflow_reference the webhook
  # resolves on) would drift on the very next update. Set once at create, then
  # immutable.
  def set_slug
    self.slug = name_slug if slug.blank?
  end
end
