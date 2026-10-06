require "test_helper"

# Funnel/campaign attribution: a `?reference=` URL param (or a landing page's
# slug) is captured first-touch into a cookie and written onto the user when
# the account is created.
class ReferenceAttributionTest < ActionDispatch::IntegrationTest
  test "a ?reference= param is captured into a cookie" do
    get faucet_path, params: { reference: "spring-campaign" }
    assert_equal "spring-campaign", cookies[:reference]
  end

  test "a ?r= param is captured into the same cookie" do
    get faucet_path, params: { r: "tiktok-bio" }
    assert_equal "tiktok-bio", cookies[:reference]
  end

  test "r wins over reference when a link carries both" do
    get faucet_path, params: { r: "short", reference: "long" }
    assert_equal "short", cookies[:reference]
  end

  test "an r-tagged visit lands on the new user at magic-link signup" do
    get faucet_path, params: { r: "tiktok-bio" }
    token = Studio::Link.create_magic_link(email: "r-ref@mcritchie.studio", age_attested: true).token
    assert_difference("User.count", 1) { post magic_link_consume_path(token: token) }
    assert_equal "tiktok-bio", User.find_by(email: "r-ref@mcritchie.studio").reference
  end

  test "the reference cookie is first-touch and not overwritten" do
    get faucet_path, params: { reference: "first" }
    get faucet_path, params: { reference: "second" }
    assert_equal "first", cookies[:reference]
  end

  # Email signup is now a unified magic link with no user form, so attribution
  # rides the first-touch cookie through the link (the same mechanism the Google
  # path uses below) rather than a hidden field on the page.
  test "magic-link signup persists the reference cookie onto the new user" do
    get faucet_path, params: { reference: "friends-test" }
    token = Studio::Link.create_magic_link(email: "ml-ref@mcritchie.studio", age_attested: true).token
    # Signup happens on the human's POST (the GET is the inert, scanner-safe
    # interstitial); the reference cookie set on the faucet visit rides through.
    assert_difference "User.count", 1 do
      post magic_link_consume_path(token: token)
    end
    assert_equal "friends-test", User.find_by(email: "ml-ref@mcritchie.studio").reference
  end

  test "email signup persists the reference onto the new user" do
    assert_difference "User.count", 1 do
      post signup_path, params: {
        user: { email: "newbie@mcritchie.studio", reference: "friends-test" },
        age_attestation: "1"
      }
    end
    assert_equal "friends-test", User.find_by(email: "newbie@mcritchie.studio").reference
  end

  test "google signup persists the reference onto the new user" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2",
      uid: "ref-9001",
      info: { email: "googlenewbie@example.com", name: "Google Newbie" }
    )
    get faucet_path, params: { reference: "friends-test" }
    assert_difference "User.count", 1 do
      # The request-phase age_attestation query param reaches the callback via
      # session["omniauth.params"] (OmniAuth snapshots request.GET).
      post "/auth/google_oauth2?age_attestation=1"
      follow_redirect!
    end
    assert_equal "friends-test", User.find_by(email: "googlenewbie@example.com").reference
  end
end
