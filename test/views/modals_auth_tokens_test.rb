require "test_helper"

# Component tier for modals/auth/_tokens — the in-contest "Get Entry Tokens"
# Stripe pack picker (task: gate-modal-stripe-cards).
#
# The defect this file first pinned: the picker never gated its pack cards on
# Stripe being live. modals/_auth:346 renders it only when entry_funding_mode
# == :stripe, which IS Payments.stripe?, so with Stripe off the buyer never
# reaches it — the gate is DEFENSIVE DEPTH, not a live buyer path (the live
# case is tokens/buy.html.erb, a page not gated by entry_funding_mode). The
# effect is still asserted on the rendered card so the depth cannot rot.
#
# The sibling (modals/auth/_paypal_tokens) once carried an identical Stripe
# "fallback" gate that was unreachable — that partial renders only under
# :paypal, i.e. Payments.paypal_checkout? true, so its else branch never ran
# (dead across all 12 provider × stripe_enabled × paypal_enabled configs). That
# dead fallback was removed (task: dedupe-stripe-gate-conjunct); the sibling now
# renders only its reachable PayPal picker, which the last test below asserts.
#
# Assert the EFFECT on the rendered card — the disabled attribute and the
# buyer-facing copy — rather than that the local was passed.
class ModalsAuthTokensTest < ActionView::TestCase
  setup do
    @stripe_was   = Rails.application.config.x.stripe_enabled
    @provider_was = Rails.application.config.x.payment_provider
    Rails.application.config.x.payment_provider = "stripe"
  end

  teardown do
    Rails.application.config.x.stripe_enabled  = @stripe_was
    Rails.application.config.x.payment_provider = @provider_was
  end

  def render_picker(stripe_enabled:)
    Rails.application.config.x.stripe_enabled = stripe_enabled
    render partial: "modals/auth/tokens"
  end

  # Every pack card must be marked disabled, not just the first — a buyer can
  # click any of them.
  test "pack cards are disabled when Stripe checkout is off" do
    html = render_picker(stripe_enabled: false)
    buttons = html.scan(/<button[^>]*>/).select { |t| t.include?("glow-pair-btn") }

    assert_equal StripePurchase.available_packs.size, buttons.length,
                 "expected one pack card per available pack"
    buttons.each_with_index do |tag, i|
      assert_match(/\sdisabled="disabled"/, tag,
                   "pack card ##{i + 1} must be disabled when Stripe is off")
    end
  end

  test "pack cards are live when Stripe checkout is on" do
    html = render_picker(stripe_enabled: true)
    buttons = html.scan(/<button[^>]*>/).select { |t| t.include?("glow-pair-btn") }

    assert_equal StripePurchase.available_packs.size, buttons.length
    buttons.each_with_index do |tag, i|
      refute_match(/\sdisabled="disabled"/, tag,
                   "pack card ##{i + 1} must be live when Stripe is on")
    end
  end

  # The footer must not promise a checkout that cannot happen.
  test "the footer tells the buyer when purchases are unavailable" do
    off = render_picker(stripe_enabled: false)
    assert_match(/temporarily unavailable/, off)
    refute_match(/Secure checkout opens in a new tab/, off)

    on = render_picker(stripe_enabled: true)
    assert_match(/Secure checkout opens in a new tab/, on)
    refute_match(/temporarily unavailable/, on)
  end

  # The sibling picker (modals/auth/_paypal_tokens) now renders ONLY its
  # reachable branch — the PayPal buttons — because its unreachable Stripe
  # "fallback" else was removed (task: dedupe-stripe-gate-conjunct). Render it
  # under the config it actually ships in (Payments.paypal_checkout? true) and
  # assert the PayPal factory mounts and NONE of the deleted Stripe-fallback
  # copy survives. This replaces the old pairing test, which deliberately
  # rendered the now-deleted dead branch.
  test "the paypal sibling renders its PayPal picker, not a Stripe fallback" do
    @paypal_was = Rails.application.config.x.paypal_enabled
    Rails.application.config.x.payment_provider = "paypal"
    Rails.application.config.x.paypal_enabled   = true

    html = render partial: "modals/auth/paypal_tokens"

    # The reachable branch mounts the PayPal buttons factory…
    assert_match(/x-data="paypalButtons\(/, html,
                 "the paypal picker must render the PayPal buttons factory")
    # …and the removed Stripe fallback's buyer-facing copy is gone.
    refute_match(/Secure checkout opens in a new tab/, html,
                 "the deleted Stripe fallback copy must not survive")
    refute_match(/temporarily unavailable/, html,
                 "the deleted Stripe fallback copy must not survive")
  ensure
    Rails.application.config.x.paypal_enabled = @paypal_was
  end
end
