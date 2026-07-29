require "test_helper"

# Component tier for modals/auth/_tokens — the in-contest "Get Entry Tokens"
# picker (task: gate-modal-stripe-cards).
#
# The defect: this picker never gated its pack cards on Stripe being live,
# while its sibling (modals/auth/_paypal_tokens) always had — so the two
# disagreed.
#
# NOT a live buyer-harm path, and neither is the sibling's. modals/_auth:346
# renders this picker only when entry_funding_mode == :stripe, which IS
# Payments.stripe?, so with Stripe off the buyer never reaches it. The sibling
# renders only under :paypal — i.e. Payments.paypal_checkout? true — which is
# the very condition its :63 branch tests, so the Stripe fallback holding its
# gate is unreachable too. Enumerated: of all 12 provider × stripe_enabled ×
# paypal_enabled configs, ZERO reach it. The gate that genuinely varies is
# tokens/buy.html.erb:70, on a page not gated by entry_funding_mode.
#
# So the sibling test below deliberately renders a branch production cannot
# reach. That is the point: it pins the two pickers together so they cannot
# drift apart again, and it fails if either gate is removed.
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

  # The two pickers must agree — the invariant the bug broke, and the reason it
  # survived: nothing compared them.
  #
  # RENDER the sibling rather than grepping both files for a variable name. The
  # first cut did the latter and asserted a SPELLING: renaming stripe_on to
  # stripe_live in both partials — behaviour-identical — turned it red, while
  # its name promised behavioural parity. Rendering catches the real thing and
  # is immune to the rename.
  #
  # Reaching the sibling's fallback requires forcing a config production never
  # renders it in (see the header) — deliberately so. The value here is the
  # PAIRING: neither picker can lose its gate without this going red.
  test "the paypal sibling disables its pack cards on the same condition" do
    # Reach the sibling's STRIPE FALLBACK branch (_paypal_tokens:70), not its
    # PayPal picker: that partial shows the PayPal buttons when
    # Payments.paypal_checkout? is true and falls back to Stripe pack cards
    # otherwise. The fallback is exactly where its stripe_on gate lives — the
    # "dormant fallback" its own comment describes.
    @paypal_was = Rails.application.config.x.paypal_enabled
    Rails.application.config.x.payment_provider = "paypal"
    Rails.application.config.x.paypal_enabled   = false
    Rails.application.config.x.stripe_enabled   = false

    html = render partial: "modals/auth/paypal_tokens"
    buttons = html.scan(/<button[^>]*>/).select { |t| t.include?("glow-pair-btn") }

    assert_equal StripePurchase.available_packs.size, buttons.length,
                 "the sibling picker must render one pack card per pack"
    buttons.each_with_index do |tag, i|
      assert_match(/\sdisabled="disabled"/, tag,
                   "sibling pack card ##{i + 1} must disable on the same condition")
    end
  ensure
    Rails.application.config.x.paypal_enabled = @paypal_was
  end
end
