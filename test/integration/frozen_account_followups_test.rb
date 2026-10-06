require "test_helper"

# [integration] turf-frozen-account-followups: the holes Carl's review of the
# account freeze (PR 912) found in it. Each case has a control: the same
# request for an account in good standing still does what it always did.
#
#   Google link        the OAuth callback is a GET, so FrozenAccountGuard
#                      (every non-GET) never sees it; the link is refused here
#   parked sign-in     a frozen parked identity with a drifted username signs in
#   wallet export      a reveal link mailed before the freeze is refused after it
#   admin freeze       a failed freeze or unfreeze is logged (rescue_and_log)
class FrozenAccountFollowupsTest < ActionDispatch::IntegrationTest
  # ── Google link ──────────────────────────────────────────────────────────

  def mock_google(uid:, email:)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: uid, info: { email: email, name: "Google Person" }
    )
  end

  test "a frozen account cannot link Google from /account" do
    user = users(:jordan)
    log_in_as(user)
    user.freeze!(reason: "test", source: "console")
    mock_google(uid: "g-frozen-#{SecureRandom.hex(3)}", email: user.email)

    get "/auth/google_oauth2/callback"

    assert_redirected_to account_path
    assert_equal FrozenAccount::MESSAGE, flash[:alert]
    assert_nil user.reload.uid, "no Google identity is linked to a frozen account"
    assert_equal user.id, session[:turf_user_id], "the refusal keeps the session"
  end

  test "control: an account in good standing links Google from /account" do
    user = users(:jordan)
    log_in_as(user)
    uid = "g-ok-#{SecureRandom.hex(3)}"
    mock_google(uid: uid, email: user.email)

    get "/auth/google_oauth2/callback"

    assert_redirected_to account_path
    assert_equal "Google account linked.", flash[:notice]
    assert_equal uid, user.reload.uid
  end

  # A wallet account whose Google sign-in was stashed for a wallet login
  # (OmniauthCallbacksController, :requires_verification). Signs the wallet in
  # by hand, as log_in_as_onchain does, but without its address update!: a
  # frozen account may not change its wallet, so the key is set first.
  def wallet_sign_in_with_stashed_google(user, frozen:)
    key = Ed25519::SigningKey.generate
    pubkey = Solana::Keypair.encode_base58(key.verify_key.to_bytes)
    user.update_column(:web3_solana_address, pubkey)
    user.freeze!(reason: "test", source: "console") if frozen
    uid = "g-#{SecureRandom.hex(4)}"
    mock_google(uid: uid, email: user.email)
    get "/auth/google_oauth2/callback"
    assert_redirected_to link_wallet_path

    get "/auth/solana/nonce"
    nonce = response.parsed_body["nonce"]
    message = "www.example.com wants you to sign in with your Solana account:\n#{pubkey}\n\nNonce: #{nonce}"
    post "/auth/solana/verify", params: { message: message, pubkey: pubkey,
                                          signature: Solana::Keypair.encode_base58(key.sign(message)) }, as: :json
    assert_response :success
    uid
  end

  test "a frozen wallet account's sign-in does not complete a stashed Google link" do
    user = users(:sam)
    wallet_sign_in_with_stashed_google(user, frozen: true)

    assert_equal user.id, session[:turf_user_id], "the wallet sign-in itself goes through"
    assert_nil user.reload.uid
  end

  test "control: the same sign-in completes the stashed Google link in good standing" do
    user = users(:sam)
    uid = wallet_sign_in_with_stashed_google(user, frozen: false)

    assert_equal uid, user.reload.uid
  end

  # ── parked identity sign-in ──────────────────────────────────────────────

  test "a frozen parked identity with a drifted username signs in by magic link" do
    user = User.create!(email: "mack@mcritchie.studio", name: "Mack McRitchie", username: "mack-x-#{SecureRandom.hex(2)}")
    user.update_column(:username, "mack-drifted-#{SecureRandom.hex(2)}")
    drifted = user.reload.username
    user.freeze!(reason: "test", source: "console")

    post magic_link_consume_path(token: magic_token(email: user.email))

    assert_response :redirect
    assert_equal user.id, session[:turf_user_id], "a frozen account still signs in"
    assert_equal drifted, user.reload.username
  end

  # ── wallet export ────────────────────────────────────────────────────────

  def mint_export_link(user)
    user.update!(export_initiated_at: Time.current)
    Rails.application.message_verifier("wallet_export_v1").generate(
      { user_id: user.id, email: user.email, initiated_at: user.export_initiated_at.to_i },
      expires_in: 30.minutes
    )
  end

  def managed_user
    user = User.create!(name: "Frida Frozen", username: "frida-#{SecureRandom.hex(2)}",
                        email: "frida-#{SecureRandom.hex(2)}@example.test", email_verified_at: Time.current)
    grant_managed_wallet!(user)
    user.reload
  end

  test "a reveal link mailed before the freeze shows no key after it" do
    user = managed_user
    token = mint_export_link(user)
    secret = Solana::Keypair.encode_base58(user.solana_keypair.to_bytes)
    user.freeze!(reason: "test", source: "console")

    get wallet_export_path(token: token)

    assert_response :forbidden
    assert_includes response.body, FrozenAccount::MESSAGE
    assert_not_includes response.body, secret
    assert_not_includes response.body, user.solana_address
  end

  test "a frozen account cannot complete self-custody from a pre-freeze link" do
    user = managed_user
    token = mint_export_link(user)
    message = WalletExportsController.prove_message(token: token, address: user.solana_address)
    signature = Solana::Keypair.encode_base58(user.solana_keypair.sign(message))
    user.freeze!(reason: "test", source: "console")

    post complete_wallet_export_path(token: token), params: { signature: signature, message: message }, as: :json

    assert_response :forbidden
    assert_equal FrozenAccount::CODE, response.parsed_body["code"]
    assert_nil user.reload.self_custodied_at
  end

  test "control: the same link reveals the key for an account in good standing" do
    user = managed_user
    token = mint_export_link(user)

    get wallet_export_path(token: token)

    assert_response :success
    assert_includes response.body, user.solana_address
  end

  # ── admin freeze and unfreeze ────────────────────────────────────────────

  def with_failing(method_name)
    original = User.instance_method(method_name)
    User.define_method(method_name) { |**| raise ActiveRecord::StatementInvalid, "connection lost" }
    yield
  ensure
    User.define_method(method_name, original)
  end

  def admin_setup
    User.where(slug: nil).find_each { |u| u.update_column(:slug, "fixture-#{u.id}") }
    log_in_as(users(:alex))
    users(:jordan).reload
  end

  test "a freeze that fails is logged against the player and answered with an alert" do
    player = admin_setup

    with_failing(:freeze!) do
      assert_difference -> { ErrorLog.count }, 1 do
        post admin_freeze_user_path(player.slug), params: { reason: "chargeback" }
      end
    end

    assert_redirected_to admin_users_path
    assert_equal "Could not freeze #{player.display_name}.", flash[:alert]
    assert_equal player, ErrorLog.order(:id).last.target
    assert_not player.reload.frozen?
  end

  test "an unfreeze that fails is logged against the player and answered with an alert" do
    player = admin_setup
    player.freeze!(reason: "dispute", source: "console")

    with_failing(:unfreeze!) do
      assert_difference -> { ErrorLog.count }, 1 do
        delete admin_unfreeze_user_path(player.slug), params: { reason: "dispute won" }
      end
    end

    assert_redirected_to admin_users_path
    assert_equal "Could not unfreeze #{player.display_name}.", flash[:alert]
    assert player.reload.frozen?
  end

  test "control: a freeze that succeeds logs nothing" do
    player = admin_setup

    assert_no_difference -> { ErrorLog.count } do
      post admin_freeze_user_path(player.slug), params: { reason: "chargeback" }
    end
    assert player.reload.frozen?
  end
end
