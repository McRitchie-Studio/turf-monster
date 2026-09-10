require "test_helper"
require "minitest/mock"

# /account renders a "Cash out" shortcut button that points at
# /wallet#cash-out (the same identity-gating as the inline form there).
# Self-custodied users see a "manage from your own wallet" callout
# instead. Phantom-only users see neither.
class AccountsCashOutButtonTest < ActionDispatch::IntegrationTest
  setup do
    @managed = User.create!(
      name: "Cash Out Cathy", username: "co-#{SecureRandom.hex(2)}",
      email: "co-#{SecureRandom.hex(2)}@example.test",
      email_verified_at: Time.current
    )
    grant_managed_wallet!(@managed)
    assert @managed.reload.managed_wallet?
  end

  test "managed non-self-custodied user sees the Cash out button on /account" do
    log_in_as(@managed)
    get account_path
    assert_response :success
    # Button → /wallet#cash-out
    assert_match(/<a[^>]+href="\/wallet#cash-out"[^>]*>\s*Cash out\s*<\/a>/, response.body)
    # Self-custody callout must NOT render for a non-self-custodied user.
    assert_no_match(/cash out from your own wallet/i, response.body)
  end

  test "self-custodied user sees the callout instead of the button" do
    @managed.update!(self_custodied_at: 1.minute.ago)
    log_in_as(@managed)
    get account_path
    assert_response :success
    assert_no_match(/href="\/wallet#cash-out"/, response.body)
    assert_match(/cash out from your own wallet/i, response.body)
  end

  test "phantom-only user sees neither" do
    phantom_kp = Solana::Keypair.generate
    phantom = User.create!(
      name: "Phantom Pete", username: "pp-#{SecureRandom.hex(2)}",
      email: "pp-#{SecureRandom.hex(2)}@example.test",
      web3_solana_address: phantom_kp.address,
      email_verified_at: Time.current
    )
    # User#after_create generates a managed wallet on top — null it out so
    # this user is phantom-only (matches the canonical "linked Phantom"
    # wallet shape in the wallet_kind enum).
    phantom.update_columns(web2_solana_address: nil, encrypted_web2_solana_private_key: nil)

    log_in_as(phantom)
    get account_path
    assert_response :success
    assert_no_match(/href="\/wallet#cash-out"/, response.body)
    assert_no_match(/cash out from your own wallet/i, response.body)
  end

  test "the /wallet page wires #cash-out to auto-open the form" do
    log_in_as(@managed)
    # Stub the Solana RPC so the page renders without hitting devnet.
    fake_vault = Object.new
    fake_vault.define_singleton_method(:sync_balance) { |_addr| { balance_dollars: 50.0 } }
    Solana::Vault.stub :new, fake_vault do
      get wallet_path
    end
    assert_response :success
    # The collapse trigger reads window.location.hash on mount.
    assert_match(/x-data="\{ open: window\.location\.hash === '#cash-out'/, response.body)
    # And the card itself has the anchor id.
    assert_match(/<div id="cash-out"/, response.body)
  end

end
