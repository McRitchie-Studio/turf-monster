require "test_helper"

class OmniauthCallbacksControllerTest < ActionDispatch::IntegrationTest
  # These tests exercise the legal-age attestation gate as designed (ON).
  # The flag is parked off by default for the first contest; the off state
  # is covered in age_attestation_flag_test.rb.
  setup    { ENV["ENABLE_AGE_ATTESTATION"] = "true" }
  teardown { ENV.delete("ENABLE_AGE_ATTESTATION") }

  setup do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "112233",
      info: { email: "googleuser@example.com", name: "Google User" }
    )
  end

  test "google callback creates user and logs in" do
    assert_difference "User.count", 1 do
      # Drive the REAL transport: the legal-age attestation rides the POSTed
      # OAuth request phase as a query param (exactly what /auth/google_popup
      # and the /signin form emit); OmniAuth snapshots request.GET into
      # session["omniauth.params"], which the callback pops back out.
      post "/auth/google_oauth2?age_attestation=1"
      follow_redirect!
    end

    # A brand-new Google signup lands on the app ROOT, not the entry-token
    # upsell: web3-only onboarding (default ON since 2026-08-15) mints no
    # custodial wallet, so /tokens/buy would sell an entry token this account
    # cannot pay for. OmniauthCallbacksController drops the upsell whenever the
    # chain still owes the wallet step, and the setup modal opens on the root
    # page instead. With the switch off, the upsell returns.
    assert_redirected_to root_path
    user = User.find_by(email: "googleuser@example.com")
    assert_nil user.web2_solana_address, "web3-only onboarding mints no custodial wallet"
    assert_equal user.id, session[:turf_user_id]
    assert user.age_attested_at.present?, "new Google signup must be stamped age-attested"
  end

  # ── legal-age attestation (underwriting compliance) ───────────────────────
  test "google callback REFUSES a brand-new signup without the legal-age attestation" do
    assert_no_difference "User.count" do
      get "/auth/google_oauth2/callback"
    end
    assert_redirected_to signin_path
    assert_match(/legal age/i, flash[:alert])
    assert_nil session[:turf_user_id]
  end

  test "google callback logs in existing user when email is verified (OPSEC-005)" do
    alex = users(:alex)
    alex.update!(email_verified_at: Time.current)  # precondition for silent linking
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "445566",
      info: { email: alex.email, name: "Alex" }
    )

    assert_no_difference "User.count" do
      get "/auth/google_oauth2/callback"
    end

    assert_redirected_to root_path
    assert_equal alex.id, session[:turf_user_id]
  end

  test "google callback refuses silent link to unverified existing user (OPSEC-005)" do
    alex = users(:alex)
    alex.update!(email_verified_at: nil)
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "445566",
      info: { email: alex.email, name: "Alex" }
    )

    assert_no_difference "User.count" do
      get "/auth/google_oauth2/callback"
    end

    assert_redirected_to signin_path
    assert_nil session[:turf_user_id]
  end

  test "failure redirects to login" do
    get "/auth/failure"
    assert_redirected_to signin_path
  end

  test "popup entrypoint renders a POST handoff form" do
    get "/auth/google_popup", params: { age_attestation: "1" }
    assert_response :success
    assert_select "form[method=post][action=?]", "/auth/google_oauth2?age_attestation=1"
  end

  # ── Feature 1: Google sign-in colliding with a wallet-secured account ──────

  test "google callback on a wallet account routes to the wallet-login view" do
    sam = users(:sam) # fixture: has a web3 wallet, email unverified
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "g-#{SecureRandom.hex(4)}",
      info: { email: sam.email, name: "Sam" }
    )

    assert_no_difference "User.count" do
      get "/auth/google_oauth2/callback"
    end

    assert_redirected_to link_wallet_path
    assert_nil session[:turf_user_id], "should not be logged in until the wallet login completes"

    follow_redirect!
    assert_response :success
    assert_select "h1", text: /Log In with Your Wallet/
  end

  test "wallet login completes the stashed Google link" do
    sam = users(:sam)
    google_uid = "g-#{SecureRandom.hex(4)}"
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: google_uid,
      info: { email: sam.email, name: "Sam" }
    )
    get "/auth/google_oauth2/callback"
    assert_redirected_to link_wallet_path

    # A real wallet login consumes the stash and links Google (both factors proven).
    log_in_as_onchain(sam)

    sam.reload
    assert_equal "google_oauth2", sam.provider
    assert_equal google_uid, sam.uid
    assert_equal sam.id, session[:turf_user_id]
  end

  test "GET /login/wallet without a pending link redirects to login" do
    get link_wallet_path
    assert_redirected_to signin_path
  end
end
