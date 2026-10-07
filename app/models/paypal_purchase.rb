# Audit log for PayPal / Venmo token purchases — the PayPal-rails sibling of
# StripePurchase. The minted tokens live on-chain as EntryTokenAccount PDAs in
# turf-vault; this row maps a PayPal order/capture to its on-chain mint TX(s)
# for chargeback / refund forensics.
#
# Pack definitions stay on StripePurchase::PACKS — single source of truth for
# both providers (see StripePurchase.pack).
#
# Status walk: pending → captured → minted, with refunded / failed terminals.
# "captured" is PayPal-specific — the payment cleared (Orders v2 capture
# COMPLETED) but the on-chain mint hasn't finished yet.
class PaypalPurchase < ApplicationRecord
  include Sluggable
  include MintablePurchase

  STATUSES = %w[pending captured minted refunded failed].freeze

  belongs_to :user

  validates :paypal_order_id, uniqueness: true, allow_nil: true
  validates :pack_id, presence: true
  validates :quantity, numericality: { greater_than: 0 }
  validates :price_cents, numericality: { greater_than: 0 }
  validates :status, inclusion: { in: STATUSES }

  scope :minted,    -> { where(status: "minted") }
  scope :pending,   -> { where(status: "pending") }
  scope :captured,  -> { where(status: "captured") }
  scope :refunded,  -> { where(status: "refunded") }
  scope :for_order, ->(order_id) { where(paypal_order_id: order_id) }

  # Atomic pending → captured transition — the exactly-once fulfillment gate.
  # The paypal_capture endpoint and the PAYMENT.CAPTURE.COMPLETED webhook can
  # race; the single-row `UPDATE ... WHERE status = 'pending'` guarantees
  # exactly one caller wins (returns true) and enqueues the mint.
  # TokenPurchaseJob's source_ref idempotency (OPSEC-009) backstops any
  # double-enqueue regardless.
  def begin_fulfillment!(capture_id:)
    won = self.class.where(id: id, status: "pending").update_all(
      status: "captured",
      capture_id: capture_id,
      captured_at: Time.current,
      updated_at: Time.current
    ) == 1
    reload
    won
  end

  # Validates a PayPal capture object (REST capture response slice or the
  # PAYMENT.CAPTURE.COMPLETED webhook resource) against this purchase:
  # completed, USD, and the exact pack amount — never trust client amounts.
  def capture_matches?(capture)
    capture.present? &&
      capture["status"] == "COMPLETED" &&
      capture.dig("amount", "currency_code") == "USD" &&
      capture.dig("amount", "value") == expected_amount_value
  end

  # eCheck-funded / risk-review captures come back status PENDING
  # (status_details.reason ECHECK / PENDING_REVIEW): the buyer HAS paid, the
  # money is in flight, and PAYMENT.CAPTURE.COMPLETED arrives when it clears.
  # Same amount discipline as capture_matches? — a pending capture for the
  # wrong amount/currency is NOT a hold we honor.
  def capture_pending?(capture)
    capture.present? &&
      capture["status"] == "PENDING" &&
      capture.dig("amount", "currency_code") == "USD" &&
      capture.dig("amount", "value") == expected_amount_value
  end

  # PayPal Orders v2 amounts are decimal strings ("49.00").
  def expected_amount_value
    format("%.2f", price_cents / 100.0)
  end

  private

  def name_slug
    # No stable external id at create time (the PayPal order id arrives after
    # the row exists), so the slug is pure entropy. Doubles as the order's
    # invoice_id — see Paypal::Client#create_order.
    "paypal_#{SecureRandom.hex(6)}"
  end

  # The slug is written once, at create, and never again: name_slug here is
  # fresh entropy each call, and PayPal echoes the slug back as the invoice_id
  # that the webhook's resolution and PayPal-invoice to DB reconciliation match
  # on. Sluggable (studio-engine >= 0.93) derives only on a new or blank-slug
  # row; this override keeps an explicit slug and fills only a blank one.
  def set_slug
    self.slug = name_slug if slug.blank?
  end
end
