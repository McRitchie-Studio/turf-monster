require "test_helper"

# /account balance tiles are hydrated client-side from on-chain truth:
# the walletRefresh Alpine component fires refreshSession() on load and
# from the "Refresh Wallet" button, and refreshSession fills any element
# tagged data-wallet-tile="usdc|usdt|sol|tokens". The server render is
# RPC-free (placeholders), so these hooks are the contract — if a tile
# loses its tag, it silently sticks at "—" forever (the bug this fixed).
class AccountsWalletRefreshTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      name: "Refresh Rita", username: "rr-#{SecureRandom.hex(2)}",
      email: "rr-#{SecureRandom.hex(2)}@example.test",
      email_verified_at: Time.current
    )
    # The balance tiles need a wallet to hydrate; signup stopped minting one
    # when web3-only onboarding became the default (2026-08-15).
    grant_managed_wallet!(@user)
    assert @user.reload.solana_connected?
  end

  test "account page renders walletRefresh component with all four tile hooks" do
    log_in_as(@user)
    get account_path
    assert_response :success

    assert_match(/x-data="walletRefresh\(\)"/, response.body)
    %w[usdc usdt sol tokens].each do |key|
      assert_match(/data-wallet-tile="#{key}"/, response.body,
                   "expected a data-wallet-tile=\"#{key}\" hook on /account")
    end
    assert_match(/Refresh Wallet/, response.body)
  end

  test "tiles render placeholders, not zeros, when balances are unfetched" do
    log_in_as(@user)
    get account_path
    assert_response :success

    # The render path is RPC-free — the USDC tile must ship as the "—"
    # placeholder (refreshSession only overwrites with real numbers, so a
    # $0.00 here would mean a server-side fabricated zero).
    usdc_tile = response.body[/data-wallet-tile="usdc"[^>]*>\s*([^<]*)</, 1]
    assert_equal "—", usdc_tile&.strip
  end
end
