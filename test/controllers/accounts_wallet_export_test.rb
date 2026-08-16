require "test_helper"

class AccountsWalletExportTest < ActionDispatch::IntegrationTest
  setup do
    # Build users inline to control wallet state precisely; the global
    # fixtures don't include a managed-wallet user and adding one would
    # ripple through unrelated suites.
    @managed = User.create!(
      name: "Maggie Managed", username: "maggie-managed",
      email: "managed-#{SecureRandom.hex(2)}@example.test",
      email_verified_at: Time.current
    )
    # Minted explicitly: after_create stopped doing it when web3-only onboarding
    # became the default (2026-08-15). Export is a managed-wallet-only feature,
    # so this user has to be one.
    grant_managed_wallet!(@managed)
    assert @managed.reload.managed_wallet?, "fixture setup: expected managed wallet"

    # Use Solana::Keypair to mint a fresh base58 address — the test fixtures
    # include a phantom user (sam) and the column has a uniqueness validator.
    phantom_kp = Solana::Keypair.generate
    @phantom = User.create!(
      name: "Penny Phantom", username: "penny-phantom",
      email: "phantom-#{SecureRandom.hex(2)}@example.test",
      web3_solana_address: phantom_kp.address,
      email_verified_at: Time.current
    )
    # Belt and braces. Web3-only onboarding (default ON since 2026-08-15) means
    # after_create mints nothing, so this user is already key-less — but the flag
    # is revertible in one env change, and with it off after_create is
    # unconditional for non-admins and would hand the phantom user a managed key
    # on top. The "managed-only export" rule keys off managed_wallet?, and the
    # canonical phantom user in our flows holds no server-side key material.
    # Nulling it out keeps this suite honest on BOTH sides of the switch.
    @phantom.update_columns(web2_solana_address: nil, encrypted_web2_solana_private_key: nil)
  end

  test "initiate requires login" do
    # XHR/JSON callers (the in-modal initiate button) get a 401 JSON; HTML
    # redirects to /login per ApplicationController#require_authentication.
    post initiate_wallet_export_account_path, as: :json
    assert_response :unauthorized
  end

  test "initiate refuses phantom-only (no managed key to export)" do
    log_in_as(@phantom)
    post initiate_wallet_export_account_path
    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_match(/managed-wallet/i, body["error"])
  end

  test "initiate refuses already-self-custodied" do
    @managed.update!(self_custodied_at: 1.minute.ago)
    log_in_as(@managed)
    post initiate_wallet_export_account_path
    assert_response :forbidden
    body = JSON.parse(response.body)
    assert_match(/already self-custodied/i, body["error"])
  end

  # Passwordless (Lazarus audit #4): the old "recent password reauth" gate is
  # gone. A passwordless managed user (magic-link / Google) can now initiate
  # export — the emailed reveal token is the out-of-band lock, and requiring a
  # password would have permanently locked these users out of self-custody.
  test "initiate works for a passwordless managed user (no password reauth gate)" do
    log_in_as(@managed)
    assert_difference "EmailDelivery.count", 1 do
      post initiate_wallet_export_account_path
    end
    assert_response :success
    assert JSON.parse(response.body)["success"]
    assert_not_nil @managed.reload.export_initiated_at
  end

  test "initiate refuses without verified email" do
    @managed.update!(email_verified_at: nil)
    log_in_as(@managed)
    post initiate_wallet_export_account_path
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_match(/verify an email/i, body["error"])
  end

  test "happy path stamps export_initiated_at + enqueues mailer" do
    log_in_as(@managed)
    assert_nil @managed.export_initiated_at

    assert_difference "EmailDelivery.count", 1 do
      post initiate_wallet_export_account_path
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert body["success"]
    assert_match(/magic link/i, body["message"])

    @managed.reload
    assert_not_nil @managed.export_initiated_at
    assert_in_delta Time.current, @managed.export_initiated_at, 5.seconds
  end

  test "second initiate refreshes export_initiated_at + invalidates the first token" do
    log_in_as(@managed)

    post initiate_wallet_export_account_path
    @managed.reload
    first_initiated = @managed.export_initiated_at

    # Build a token for the first initiate
    first_token = Rails.application.message_verifier("wallet_export_v1").generate(
      { user_id: @managed.id, email: @managed.email, initiated_at: first_initiated.to_i },
      expires_in: 30.minutes
    )

    travel 2.seconds do
      post initiate_wallet_export_account_path
      @managed.reload
      assert_operator @managed.export_initiated_at, :>, first_initiated, "second initiate should bump the timestamp"
    end

    # The first token now refers to a stale initiated_at — show should refuse.
    get wallet_export_path(token: first_token)
    assert_response :gone
    assert_match(/newer export link/i, response.body)
  end

  test "WalletExportsController#show renders the reveal page with both key formats" do
    log_in_as(@managed)
    post initiate_wallet_export_account_path
    @managed.reload

    token = Rails.application.message_verifier("wallet_export_v1").generate(
      { user_id: @managed.id, email: @managed.email, initiated_at: @managed.export_initiated_at.to_i },
      expires_in: 30.minutes
    )

    get wallet_export_path(token: token)
    assert_response :success
    # The address shows so the user can verify it matches the wallet they
    # import into.
    assert_includes response.body, @managed.solana_address
    # Both formats appear in the rendered HTML.
    keypair      = @managed.solana_keypair
    expected_b58 = Solana::Keypair.encode_base58(keypair.to_bytes)
    expected_arr = "[" + keypair.to_bytes.bytes.join(",") + "]"
    assert_includes response.body, expected_b58, "base58 secret should render"
    assert_includes response.body, expected_arr, "JSON array secret should render"
  end

  test "WalletExportsController#show rejects garbage tokens" do
    get wallet_export_path(token: "not-a-real-token")
    assert_response :gone
    assert_match(/invalid or expired/i, response.body)
  end

  test "token bound to email — changing email after invalidates" do
    log_in_as(@managed)
    post initiate_wallet_export_account_path
    @managed.reload
    token = Rails.application.message_verifier("wallet_export_v1").generate(
      { user_id: @managed.id, email: @managed.email, initiated_at: @managed.export_initiated_at.to_i },
      expires_in: 30.minutes
    )

    # Operator-side rename to a different (verified) email after token issue
    @managed.update!(email: "new-#{@managed.email}", email_verified_at: Time.current)

    get wallet_export_path(token: token)
    assert_response :gone
    assert_match(/different email/i, response.body)
  end

end
