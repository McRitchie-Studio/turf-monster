require "test_helper"
require "minitest/mock"

# Component coverage for the shared Buy USDC button on /account (ui-only).
# It funds the wallet via the Coinbase CDP onramp and must render for BOTH web2
# (managed) and web3 (Phantom) connected users, reuse the global cdp-ramp modal,
# and degrade to a disabled button + explainer in geo-blocked states — the same
# contract as /wallet, now served from shared/_buy_usdc_button + _geo_note.
class AccountsBuyUsdcButtonTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:jordan)
  end

  # AppFlags reads ENV directly — save/restore per case (same shape as
  # WalletsCdpRampTest).
  def with_cdp_ramp(value = "true")
    original = ENV["ENABLE_CDP_RAMP"]
    value.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = value
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = original
  end

  # Stub the vault so any balance read NoMethodErrors → rescues to nil/0 (never
  # hits RPC). The stub must not respond to #call or minitest invokes it.
  def get_account
    Solana::Vault.stub :new, Object.new do
      get account_path
    end
  end

  def managed!(user = @user)
    user.update!(web2_solana_address: "ManagedWallet#{SecureRandom.hex(4)}",
                 encrypted_web2_solana_private_key: "x", web3_solana_address: nil)
  end

  def phantom!(user = @user)
    user.update!(web3_solana_address: "PhantomWallet#{SecureRandom.hex(4)}",
                 web2_solana_address: nil, encrypted_web2_solana_private_key: nil)
  end

  test "web2 (managed) user sees an enabled Buy USDC button wired to the cdp-ramp modal" do
    with_cdp_ramp do
      managed!
      log_in_as @user
      get_account
      assert_response :success

      assert_select "button[data-cdp-buy-button]", count: 1
      assert_select "button[data-cdp-buy-button][disabled]", count: 0
      assert_select "button[data-cdp-buy-button] img[src='/usdc-mark.svg']", count: 1
      assert_match(/Buy USDC/, response.body)
      assert_includes response.body,
        "$store.modals.open('cdp-ramp', { flow: 'buy', step: 'preflight' })"
      # The trigger has a modal to open — the host registers the cdp-ramp partial.
      assert_includes response.body, "$store.modals.current().id === 'cdp-ramp'"
    end
  end

  test "web3 (Phantom) user also sees the enabled Buy USDC button (same flow)" do
    with_cdp_ramp do
      phantom!
      log_in_as @user
      get_account
      assert_response :success

      assert_select "button[data-cdp-buy-button]", count: 1
      assert_select "button[data-cdp-buy-button][disabled]", count: 0
      assert_select "button[data-cdp-buy-button] img[src='/usdc-mark.svg']", count: 1
    end
  end

  test "geo-blocked state disables the button and shows the explainer" do
    with_cdp_ramp do
      managed!
      log_in_as @user
      Studio::GeoSetting.stub :blocked?, true do
        get_account
      end
      assert_response :success

      assert_select "button[data-cdp-buy-button][disabled]", count: 1
      assert_select "[data-cdp-geo-note]", count: 1
      assert_match(/isn't available in your state/, response.body)
    end
  end

  test "flag off → no Buy USDC button on /account" do
    with_cdp_ramp(nil) do
      managed!
      log_in_as @user
      get_account
      assert_response :success

      assert_select "[data-cdp-buy-button]", count: 0
    end
  end

  test "connected flag on but no wallet → no Buy USDC button (nothing to buy into)" do
    with_cdp_ramp do
      @user.update_columns(web2_solana_address: nil, encrypted_web2_solana_private_key: nil,
                           web3_solana_address: nil)
      log_in_as @user
      get_account
      assert_response :success

      assert_select "[data-cdp-buy-button]", count: 0
    end
  end
end
