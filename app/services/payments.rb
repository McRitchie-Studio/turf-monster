# Single source of truth for the active fiat payment provider.
#
# The operator picks the provider via PAYMENT_PROVIDER (resolved at boot by
# config/initializers/paypal.rb into config.x.payment_provider — tests toggle
# that config the same way tokens_controller_test toggles x.stripe_enabled):
#   "stripe" — dormant Stripe card checkout fallback; must be explicit
#   "paypal" — PayPal / Venmo buttons (Orders v2)
#   "none"   — no fiat onramp (default when unset; token purchases hidden)
#
# The provider reads "none" whenever the fiat rails are parked
# (AppFlags.fiat_rails? off), whatever PAYMENT_PROVIDER says, so every
# stripe? / paypal? / paypal_checkout? caller is gated by the one flag.
module Payments
  PROVIDERS = %w[stripe paypal none].freeze

  def self.provider
    return "none" unless AppFlags.fiat_rails?

    configured = Rails.application.config.x.payment_provider
    configured.presence || "none"
  end

  # Defers to config.x.stripe_enabled so STRIPE_CHECKOUT_DISABLED (the
  # checkout-only kill-switch, config/initializers/stripe.rb) is a single
  # truth — Stripe is the active provider only when selected AND enabled.
  def self.stripe?
    provider == "stripe" && Rails.application.config.x.stripe_enabled
  end

  def self.paypal?
    provider == "paypal"
  end

  # The render/accept gate for PayPal checkout: operator flag AND credentials.
  # Views branch on this (pack picker, /tokens/buy, JS SDK include) and
  # paypal_order (order CREATION) refuses without it, so the UI can never
  # offer buttons the backend would reject. paypal_capture and the webhook
  # are deliberately NOT gated on it — rolling back to stripe must still
  # drain in-flight approved orders (see docs/PAYPAL_VENMO.md "Heroku flip").
  def self.paypal_checkout?
    paypal? && Rails.application.config.x.paypal_enabled
  end

  def self.none?
    provider == "none"
  end
end
