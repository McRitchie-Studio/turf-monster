require "bigdecimal"

# Audit log for Aeropay bank-payment (pay-by-bank ACH + RTP) entry-token
# purchases — the Aeropay-rails sibling of CoinflowPurchase / PaypalPurchase /
# StripePurchase. The minted tokens live on-chain as EntryTokenAccount PDAs in
# turf-vault; this row maps an Aeropay deposit settlement to its on-chain mint
# TX(s) for chargeback / refund forensics.
#
# Pack definitions stay on StripePurchase::PACKS — single source of truth for
# every provider (see StripePurchase.pack). "Buy 1 entry" is pack "single"
# (quantity 1, price_cents 19_00).
#
# Status walk: pending → captured → minted, with refunded / failed terminals.
# "captured" is the post-`transaction_completed`, pre-mint state — Aeropay's
# deposit cleared for the exact pack amount but the on-chain mint hasn't
# finished yet. (For a standard ACH pay-in, "completed" is APPROVED not settled
# — see Aeropay::Fulfillment.)
#
# Money model note: [FLAG] we assume Aeropay reports the amount as a DECIMAL
# DOLLARS value ("19.00") with a top-level "USD" currency (not cents-native like
# Coinflow). capture_matches? converts to cents and compares against the pack
# price. If the sandbox turns out to report cents, capture_matches? fails closed
# (never mints) — verify against dev.aero.inc/docs before go-live.
class AeropayPurchase < ApplicationRecord
  include Sluggable
  include MintablePurchase

  STATUSES = %w[pending captured minted refunded failed].freeze

  belongs_to :user

  validates :aeropay_reference, uniqueness: true, allow_nil: true
  validates :aeropay_transaction_id, uniqueness: true, allow_nil: true
  validates :pack_id, presence: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :price_cents, numericality: { greater_than: 0 }
  validates :status, inclusion: { in: STATUSES }

  scope :minted,          -> { where(status: "minted") }
  scope :pending,         -> { where(status: "pending") }
  scope :captured,        -> { where(status: "captured") }
  scope :refunded,        -> { where(status: "refunded") }
  scope :for_reference,   ->(reference) { where(aeropay_reference: reference) }
  scope :for_transaction, ->(transaction_id) { where(aeropay_transaction_id: transaction_id) }

  # Atomic pending → captured transition — the exactly-once fulfillment gate.
  # An Aeropay `transaction_completed` webhook can be redelivered (webhooks may
  # arrive more than once); the single-row `UPDATE ... WHERE status = 'pending'`
  # guarantees exactly one caller wins (returns true) and enqueues the mint,
  # stamping the settlement transaction id atomically. TokenPurchaseJob's
  # source_ref idempotency (OPSEC-009) backstops any double-enqueue regardless.
  #
  # The transaction id is already stamped at order time (create_deposit returns
  # it); re-stamping the identical id here on the same row is a harmless no-op
  # and keeps the CAS shape identical to CoinflowPurchase#begin_fulfillment!.
  def begin_fulfillment!(capture_id:)
    won = self.class.where(id: id, status: "pending").update_all(
      status: "captured",
      aeropay_transaction_id: capture_id,
      captured_at: Time.current,
      updated_at: Time.current
    ) == 1
    reload
    won
  end

  # Validates an Aeropay settlement payload against this purchase before
  # anything mints — never trust a client-reported amount. [FLAG] We read a
  # DECIMAL-DOLLARS `amount` ("19.00") + a "USD" currency, tolerating either a
  # scalar amount or a nested { value:, currency: } object. Converted to cents
  # and matched against the pack price.
  def capture_matches?(payload)
    return false if payload.blank?
    cents = self.class.amount_cents(payload)
    self.class.currency(payload) == "USD" && cents == expected_amount_cents
  end

  def expected_amount_cents
    price_cents
  end

  # [FLAG] Amount → integer cents. Accepts "19.00" / 19.0 / { "value" => "19.00" }.
  def self.amount_cents(payload)
    raw = payload["amount"]
    raw = raw["value"] if raw.is_a?(Hash)
    return nil if raw.nil?
    (BigDecimal(raw.to_s) * 100).round
  rescue ArgumentError
    nil
  end

  # [FLAG] Currency lives top-level ("currency") or nested under a
  # { amount: { currency: } } object. GUARD the nested read: when `amount` is a
  # SCALAR ("19.00" / 19 — the assumed Aeropay shape) with no top-level currency,
  # a bare `payload.dig("amount", "currency")` raises TypeError on the String/Int
  # (the .dig-on-non-hash trap coinflow-hardening PR #212 fixed). An odd shape must
  # degrade to nil → capture_matches? false → 200 ack — never a 500 that
  # retry-loops and, firing BEFORE the CAS, strands a paid settlement unminted.
  def self.currency(payload)
    amount = payload["amount"]
    nested = amount.is_a?(Hash) ? amount["currency"] : nil
    (payload["currency"] || nested).to_s.upcase
  end

  private

  def name_slug
    # No stable external id at create time (the deposit's transaction id only
    # exists after create_deposit returns), so the slug is pure entropy. It IS
    # the aeropay_reference we hand Aeropay as externalId and resolve on.
    "aeropay_#{SecureRandom.hex(6)}"
  end

  # NEUTRALIZE Sluggable's per-save re-derive (same trap CoinflowPurchase /
  # PaypalPurchase#set_slug document): the engine's `before_save :set_slug`
  # reassigns `slug = name_slug` on EVERY save, and name_slug here is fresh
  # entropy each call — without this override the slug (and thus the
  # aeropay_reference the webhook resolves on) would drift on the very next
  # update. Set once at create, then immutable.
  def set_slug
    self.slug = name_slug if slug.blank?
  end
end
