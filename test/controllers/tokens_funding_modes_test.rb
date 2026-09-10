require "test_helper"

# The auth modal's tokens-picker step + /tokens/buy switch funding modes on
# the provider flags: PayPal/Venmo when enabled, dormant Stripe packs when
# explicitly selected, the CDP Buy-USDC handoff when card checkout is off and
# ENABLE_CDP_RAMP is on, and an honest offline card when both are off.
class TokensFundingModesTest < ActionDispatch::IntegrationTest
  setup do
    @stripe_was = Rails.application.config.x.stripe_enabled
    @provider_was = Rails.application.config.x.payment_provider
  end

  teardown do
    Rails.application.config.x.stripe_enabled = @stripe_was
    Rails.application.config.x.payment_provider = @provider_was
  end

  def with_cdp_ramp(value = "true")
    original = ENV["ENABLE_CDP_RAMP"]
    value.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = value
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = original
  end

  test "picker offers the CDP Buy USDC handoff when stripe is off and the ramp is on" do
    Rails.application.config.x.stripe_enabled = false
    with_cdp_ramp do
      # SIGNED IN. The handoff is gated on cdp_ramp_modal_available?, which reads
      # logged_in? as well as the flag, because the host registers the cdp-ramp
      # modal under logged_in? too. This asserted the handoff on a GUEST page,
      # where cdp-ramp is never registered — it was pinning a dead button.
      log_in_as users(:jordan)
      get contests_path
      assert_response :success
      assert_includes response.body, "Add USDC to Play"
      assert_includes response.body, "Buy USDC with Coinbase"
      assert_includes response.body, "$store.modals.swap('cdp-ramp'"
      refute_includes response.body, "Get Entry Tokens"
    end
  end

  test "the picker withholds the CDP handoff on a guest-rendered layout" do
    # The auth modal is registered UNGATED (it is the signup surface) while
    # cdp-ramp is registered under logged_in?, so on this page the Buy CTA would
    # swap to a modal id that was never emitted. The step still says something.
    Rails.application.config.x.stripe_enabled = false
    with_cdp_ramp do
      get contests_path
      assert_response :success
      assert_includes response.body, "Add USDC to Play"
      assert_includes response.body, "Purchases temporarily offline"
      refute_includes response.body, "$store.modals.swap('cdp-ramp'"
    end
  end

  test "picker keeps the Stripe packs byte-for-byte while stripe is explicitly enabled" do
    Rails.application.config.x.stripe_enabled = true
    Rails.application.config.x.payment_provider = "stripe"
    with_cdp_ramp do
      get contests_path
      assert_response :success
      assert_includes response.body, "tokens-waiting"
      # Refute the picker's CDP-buy card (auth/_usdc_funding's cdp-on branch) by
      # its unique copy rather than by "Buy USDC with Coinbase", which the
      # wallet-topup modal also renders. Both surfaces now gate that copy on
      # cdp_ramp_modal_available?, so on this guest page neither draws it — but
      # the unique string is still the honest way to name the picker's mode.
      refute_includes response.body, "Pay with debit, Apple Pay"
    end
  end

  test "picker degrades to the offline card when both providers are off" do
    Rails.application.config.x.stripe_enabled = false
    with_cdp_ramp(nil) do
      get contests_path
      assert_response :success
      assert_includes response.body, "Purchases temporarily offline"
      # Refute the picker's CDP-buy card by its unique copy (see the stripe-on
      # test): "Buy USDC with Coinbase" is shared with the wallet-topup modal,
      # so that string never proved the picker's mode on its own.
      refute_includes response.body, "Pay with debit, Apple Pay"
    end
  end

  test "STRIPE_CHECKOUT_DISABLED flips stripe_enabled off without unsetting the key" do
    original_key = ENV["STRIPE_SECRET_KEY"]
    original_provider = ENV["PAYMENT_PROVIDER"]
    ENV["STRIPE_SECRET_KEY"] = "sk_test_x" if original_key.blank?
    ENV["PAYMENT_PROVIDER"] = "stripe"
    ENV["STRIPE_CHECKOUT_DISABLED"] = "true"
    load Rails.root.join("config/initializers/stripe.rb")
    refute Rails.application.config.x.stripe_enabled
  ensure
    ENV.delete("STRIPE_CHECKOUT_DISABLED")
    original_key.blank? ? ENV.delete("STRIPE_SECRET_KEY") : ENV["STRIPE_SECRET_KEY"] = original_key
    original_provider.blank? ? ENV.delete("PAYMENT_PROVIDER") : ENV["PAYMENT_PROVIDER"] = original_provider
    load Rails.root.join("config/initializers/stripe.rb")
  end

  test "/tokens/buy swaps dead packs for the CDP card when stripe is off and the ramp is on" do
    Rails.application.config.x.stripe_enabled = false
    with_cdp_ramp do
      log_in_as users(:jordan)
      get tokens_buy_path
      assert_response :success
      assert_includes response.body, "Buy USDC with Coinbase"
    end
  end
end
