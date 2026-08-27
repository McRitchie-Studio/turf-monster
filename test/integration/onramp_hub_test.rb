require "test_helper"

# Render-gating coverage for the Add Funds hub (modals/_onramp_hub) and its
# entry-point link in the Get Entry Tokens picker. Logic-level production
# gating per rail is covered in test/helpers/onramp_helper_test.rb; this
# asserts the wired markup actually reaches the page. Mirrors
# tokens_funding_modes_test.rb (forces the Stripe picker so the "More ways"
# link renders).
class OnrampHubTest < ActionDispatch::IntegrationTest
  setup do
    @stripe_was = Rails.application.config.x.stripe_enabled
    @provider_was = Rails.application.config.x.payment_provider
    # Force the Stripe tokens picker, which carries the "More ways" link.
    Rails.application.config.x.stripe_enabled = true
    Rails.application.config.x.payment_provider = "stripe"
  end

  teardown do
    Rails.application.config.x.stripe_enabled = @stripe_was
    Rails.application.config.x.payment_provider = @provider_was
  end

  test "the Get Entry Tokens picker links into the onramp hub" do
    get contests_path
    assert_response :success
    assert_includes response.body, "More ways to add funds"
    assert_includes response.body, "$store.modals.swap('onramp-hub'"
  end

  test "the hub shows all rails in the test environment" do
    get contests_path
    assert_response :success
    %w[coinbase coinflow aeropay paypal venmo stripe].each do |rail|
      assert_includes response.body, %(data-onramp-rail="#{rail}"),
                       "expected the #{rail} rail card to render in test env"
    end
    # Coinbase + Stripe are the wired rails; assert their exact swap targets.
    assert_includes response.body, "$store.modals.swap('cdp-ramp', { flow: 'buy', step: 'preflight' })"
    assert_includes response.body, "$store.modals.swap('auth', { step: 'tokens-picker'"
  end

  test "the hub Coinflow rail is wired to the buy-1 kickoff" do
    get contests_path
    assert_response :success
    body = response.body
    # The rail button calls the global kickoff for pack "single"…
    # PAIRED BUT ORDER-INDEPENDENT. The rail rows are built by the engine's
    # blocks/_rail_row through content_tag, which emits @click BEFORE data-*,
    # so the old "data-… then @click" shape can never match again. Lookaheads
    # keep the property that matters — this rail carries THIS handler, on the
    # same element — without pinning the order content_tag now owns.
    assert_match(%r{<button\b(?=[^>]*data-onramp-rail="coinflow")(?=[^>]*@click="tmCoinflowBuyOne\('single'\)")[^>]*>}m, body,
                 "the Coinflow rail must kick off the buy-1 flow")
    # …and the hub defines that global (the shared coinflow_script partial).
    assert_includes body, "window.tmCoinflowBuyOne"
    assert_includes body, "/tokens/coinflow_order"
  end

  test "the hub Aeropay rail is wired to the buy-1 kickoff" do
    get contests_path
    assert_response :success
    body = response.body
    # The rail button calls the global kickoff for pack "single"…
    # PAIRED BUT ORDER-INDEPENDENT. The rail rows are built by the engine's
    # blocks/_rail_row through content_tag, which emits @click BEFORE data-*,
    # so the old "data-… then @click" shape can never match again. Lookaheads
    # keep the property that matters — this rail carries THIS handler, on the
    # same element — without pinning the order content_tag now owns.
    assert_match(%r{<button\b(?=[^>]*data-onramp-rail="aeropay")(?=[^>]*@click="tmAeropayBuyOne\('single'\)")[^>]*>}m, body,
                 "the Aeropay rail must kick off the buy-1 flow")
    # …and the hub defines that global (the shared aeropay_script partial).
    assert_includes body, "window.tmAeropayBuyOne"
    assert_includes body, "/tokens/aeropay_order"
  end

  # Flag-aware degrade (Avi review 2026-06-13): the Coinbase rail buys USDC,
  # which a web2 kill-switch viewer (ENABLE_WEB2_USDC_ENTRY off) can NOT spend on
  # an entry — so a "More ways to add funds" hop from the (already-degraded)
  # wallet-topup modal must not surface a real-money USDC dead-end. The Coinbase
  # rail is gated behind !tokenFallback client-side (mirrors the wallet-topup
  # getter); the Stripe entry-token rail is NOT gated behind it, so it stays for
  # the degraded audience whenever Stripe is live (it still gates on its own
  # backend flag, so this is not a guarantee the hub is non-empty). The live
  # branching is Alpine-runtime, so it's asserted at the render level only.
  test "the hub Coinbase rail is gated behind !tokenFallback for the web2 kill-switch" do
    get contests_path
    assert_response :success
    body = response.body
    # The tokenFallback getter exists on the hub and matches the wallet-topup one.
    assert_includes body,
                    "get tokenFallback() { return $store.session.mode === 'web2' && !$store.session.web2UsdcEntry }"
    # The Coinbase rail card is wrapped in the !tokenFallback template gate.
    assert_match(%r{x-if="!tokenFallback">\s*<button\b[^>]*data-onramp-rail="coinbase"}m, body,
                 "the hub Coinbase rail must be hidden for the web2 kill-switch audience")
    # The Stripe entry-token rail is NOT gated — it stays for the degraded viewer.
    refute_match(%r{x-if="!tokenFallback">\s*<button\b[^>]*data-onramp-rail="stripe"}m, body,
                 "the Stripe token rail must remain visible in the kill-switch degrade")
  end
end
