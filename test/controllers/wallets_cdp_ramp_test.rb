require "test_helper"
require "minitest/mock"

# Render gating for the Coinbase CDP ramp frontend (spec section 14):
#   - flag off    → no Buy USDC / Cash out buttons, no cdp-ramp modal
#                   registration, no deposit-modal Coinbase option
#   - flag on     → buttons render + wire to $store.modals.open('cdp-ramp', …)
#   - geo-blocked → disabled buttons + a short explainer (deposit-modal
#                   option is OMITTED there — the picker shows no dead options)
#   - Cash out additionally carries the client-side zero-USDC gate
#
# The live flow itself (session mint → window.open → status poll → send) is
# JS-driven; Playwright e2e coverage is a noted follow-up, not in this suite.
class WalletsCdpRampTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:jordan)
  end

  # AppFlags reads ENV directly — save/restore around each case (same helper
  # shape as Cdp::RampSessionsControllerTest / Cdp::ReturnsControllerTest).
  def with_cdp_ramp(value = "true")
    original = ENV["ENABLE_CDP_RAMP"]
    value.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = value
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = original
  end

  def give_managed_wallet(user = @user)
    user.update!(web2_solana_address: "ManagedWallet#{SecureRandom.hex(4)}",
                 encrypted_web2_solana_private_key: "x")
  end

  # /wallet does a blocking balance read — stub the vault so tests never hit
  # RPC. A bare Object suffices: every vault call NoMethodErrors and the
  # controller/model rescues land on nil/0 (same pattern as
  # AccountsCashOutButtonTest). NB: the stub value must not respond to #call
  # or minitest invokes it (see test/support/fake_vault.rb gotcha).
  def get_wallet
    Solana::Vault.stub :new, Object.new do
      get wallet_path
    end
  end

  test "flag off → no CDP buttons, no modal registration, no deposit-modal option" do
    with_cdp_ramp(nil) do
      give_managed_wallet
      log_in_as @user
      get_wallet
      assert_response :success

      assert_select "[data-cdp-buy-button]", count: 0
      assert_select "[data-cdp-cashout-button]", count: 0
      assert_select "[data-cdp-buy-usdc]", count: 0
      # No modal registration in the host. (The inert cdpRampFlow factory in
      # shared/_alpine_factories ships regardless — it references nothing
      # until a cdp-ramp modal entry exists, which this proves can't happen.)
      assert_not_includes response.body, "$store.modals.current().id === 'cdp-ramp'"
    end
  end

  test "flag on + geo allowed → Buy USDC and Cash out buttons open the cdp-ramp modal" do
    with_cdp_ramp do
      give_managed_wallet
      log_in_as @user
      get_wallet
      assert_response :success

      # Buy button — enabled, opens the buy preflight.
      assert_select "button[data-cdp-buy-button]", count: 1
      assert_select "button[data-cdp-buy-button][disabled]", count: 0
      assert_includes response.body,
        "$store.modals.open('cdp-ramp', { flow: 'buy', step: 'preflight' })"

      # Cash out button — enabled server-side, with the client-side zero-USDC
      # gate (null/unknown fails open; definitive 0 disables).
      assert_select "button[data-cdp-cashout-button]", count: 1
      assert_select "button[data-cdp-cashout-button][disabled]", count: 0
      assert_includes response.body,
        "$store.modals.open('cdp-ramp', { flow: 'sell', step: 'preflight' })"
      assert_includes response.body, ":disabled=\"$store.session.usdcCents === 0\""

      # The modal host registers the cdp-ramp content partial.
      assert_includes response.body, "$store.modals.current().id === 'cdp-ramp'"

      # The wallet-deposit modal gains the Coinbase option (swap, not open —
      # it's a cross-modal handoff from inside the host).
      assert_select "[data-cdp-buy-usdc]", count: 1
      assert_includes response.body,
        "$store.modals.swap('cdp-ramp', { flow: 'buy', step: 'preflight' })"
    end
  end

  test "flag on + geo blocked → disabled buttons with an explainer; deposit option omitted" do
    with_cdp_ramp do
      give_managed_wallet
      log_in_as @user
      Studio::GeoSetting.stub :blocked?, true do
        get_wallet
      end
      assert_response :success

      assert_select "button[data-cdp-buy-button][disabled]", count: 1
      assert_select "button[data-cdp-cashout-button][disabled]", count: 1
      assert_select "[data-cdp-geo-note]", count: 2
      assert_match(/isn't available in your state/, response.body)

      # The focused deposit picker never shows a dead option.
      assert_select "[data-cdp-buy-usdc]", count: 0
    end
  end

  test "flag on but no connected wallet → no ramp buttons (nothing to buy into / sell from)" do
    with_cdp_ramp do
      @user.update_columns(web2_solana_address: nil, encrypted_web2_solana_private_key: nil,
                           web3_solana_address: nil)
      log_in_as @user
      get_wallet
      assert_response :success

      assert_select "[data-cdp-buy-button]", count: 0
      assert_select "[data-cdp-cashout-button]", count: 0
    end
  end

  test "flag on but logged out → public pages register no cdp-ramp modal" do
    with_cdp_ramp do
      get teams_path
      assert_response :success
      assert_not_includes response.body, "$store.modals.current().id === 'cdp-ramp'"
    end
  end
end
