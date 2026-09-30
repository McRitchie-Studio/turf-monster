require "test_helper"

# Claim mode (LandingPage#claim_mode): the landing page collects the SIGNUP and
# promises a free entry the operator hand-mints later. The defect it fixes: the
# tiktok page's "Claim Your Free Entry" linked into the contest, whose submit
# asks a token-less visitor for the entry fee.
#
# What has to hold, end to end: the CTA never points at the contest; a
# signed-out visitor reaches /signin carrying the confirmation page as
# return_to; BOTH sign-in paths (magic link, Google) bring them back to it; and
# the account is attributed to the page.
class LandingClaimFlowTest < ActionDispatch::IntegrationTest
  setup do
    @contest = contests(:one)
    @page = LandingPage.create!(name: "TikTok Free Entry", slug: "tiktok",
                                headline: "Free entry for TikTok followers",
                                cta_label: "Claim Your Free Entry",
                                contest: @contest, active: true, claim_mode: true)
    @claimed = landing_page_claimed_path("tiktok")
  end

  def cta
    css_select("[data-test='claim-cta']").first
  end

  def steps_text
    css_select("[data-test='funnel-how-it-works'] p.text-heading").map { |p| p.text.strip }
  end

  # ── The landing page ────────────────────────────────────────────────────

  test "signed out, the claim CTA goes to sign-in carrying the return path and the source" do
    get landing_page_path("tiktok")

    assert_response :success
    assert cta, "claim mode must render the claim CTA"
    assert_equal signin_path(return_to: @claimed, reference: "tiktok"), cta["href"]
    assert_select "a[href^=?]", contest_path(@contest.slug), { text: "Claim Your Free Entry", count: 0 },
                  "the claim CTA must never lead into the contest checkout"
  end

  test "signed in, the claim CTA goes straight to the confirmation" do
    log_in_as(users(:casey))
    get landing_page_path("tiktok")

    assert_equal @claimed, cta["href"]
  end

  test "claim mode shows the claim steps, in claim order" do
    get landing_page_path("tiktok")

    assert_equal ["Create your account", "We email your free entry", "Pick 6 teams",
                  "Submit before the contest locks"], steps_text
  end

  test "claim mode quotes the entry as free, not the contest fee" do
    @contest.update_columns(entry_fee_cents: 1900)
    get landing_page_path("tiktok")

    assert_select "p", text: "Free"
    assert_select "p", text: "Your entry"
    assert_select "p", text: "$19", count: 0
  end

  test "without claim mode the CTA and steps are unchanged" do
    @page.update!(claim_mode: false)
    get landing_page_path("tiktok")

    assert_nil cta
    assert_select "a[href=?]", contest_path(@contest.slug, scroll: 280)
    assert_equal "Create Account", steps_text[1], "the pay-to-enter steps keep their order"
  end

  # ── The confirmation page ───────────────────────────────────────────────

  test "signed out, the confirmation sends the visitor to sign in and back" do
    get @claimed

    assert_redirected_to signin_path(return_to: @claimed, reference: "tiktok")
  end

  test "signed in, it confirms the email the entry goes to and the lock time" do
    user = users(:casey)
    log_in_as(user)
    get @claimed

    assert_response :success
    assert_select "h1", text: "You're in."
    assert_select "[data-test='claim-email']", text: user.email
    assert_select "[data-test='claim-lock']", text: /Then make your 6 picks in #{Regexp.escape(@contest.name)}/
    if @contest.locks_at
      eastern = @contest.locks_at.in_time_zone("America/New_York")
      assert_select "[data-test='claim-lock']", text: /#{Regexp.escape(eastern.strftime("%B %-d at %-l:%M %p %Z"))}/
    end
  end

  test "a page without claim mode has no confirmation" do
    @page.update!(claim_mode: false)
    log_in_as(users(:casey))
    get @claimed

    assert_redirected_to landing_page_path("tiktok")
  end

  test "an inactive claim page's confirmation is not public" do
    @page.update!(active: false)
    log_in_as(users(:casey))
    get @claimed

    assert_redirected_to root_path
  end

  test "a brand-new account with no source is attributed to the page" do
    user = users(:casey)
    user.update_columns(reference: nil, created_at: 1.hour.ago)
    log_in_as(user)

    get @claimed

    assert_equal "tiktok", user.reload.reference
  end

  test "an existing source is never overwritten" do
    user = users(:casey)
    user.update_columns(reference: "friends-test", created_at: 1.hour.ago)
    log_in_as(user)

    get @claimed

    assert_equal "friends-test", user.reload.reference
  end

  test "an old account with no source is not re-labelled by a claim" do
    user = users(:casey)
    user.update_columns(reference: nil, created_at: 30.days.ago)
    log_in_as(user)

    get @claimed

    assert_nil user.reload.reference
  end

  test "a wallet-less claimant is told the entry needs a wallet" do
    user = users(:casey)
    user.update_columns(web2_solana_address: nil, web3_solana_address: nil)
    log_in_as(user)

    get @claimed

    assert_select "[data-test='claim-wallet-note']"
  end

  # ── Sign-in round trips ─────────────────────────────────────────────────

  test "the sign-in card forwards return_to into Google and the magic link" do
    get signin_path(return_to: @claimed, reference: "tiktok")

    assert_response :success
    google_action = "/auth/google_oauth2?#{{ return_to: @claimed }.to_query}"
    assert_select "form[action=?]", google_action
    assert_includes response.body, "returnTo: &quot;#{@claimed}&quot;"
  end

  test "the sign-in card refuses an off-site return_to" do
    get signin_path(return_to: "//evil.example/steal")

    assert_select "form[action=?]", "/auth/google_oauth2"
    assert_includes response.body, "returnTo: null"
    assert_select "form[action*='evil.example']", count: 0
  end

  test "magic-link signup from the claim CTA lands on the confirmation, attributed" do
    get landing_page_path("tiktok") # the reference cookie
    post magic_link_request_path, params: { email: "fan@example.com", return_to: @claimed, age_attestation: "1" },
                                  as: :json
    delivery = EmailDelivery.where(email_key: "UserMailer#magic_link").last
    token = ActiveJob::Arguments.deserialize(delivery.args).second

    assert_difference "User.count", 1 do
      post magic_link_consume_path(token: token)
    end

    assert_redirected_to @claimed
    assert_equal "tiktok", User.find_by(email: "fan@example.com").reference
  end

  test "a magic link opened in another browser still lands and attributes" do
    # No landing-page visit in THIS session: no reference cookie. The link was
    # requested elsewhere; the confirmation page is the backstop.
    token = Studio::Link.create_magic_link(email: "phone@example.com", return_to: @claimed,
                                           age_attested: true).token
    post magic_link_consume_path(token: token)
    assert_redirected_to @claimed

    follow_redirect!
    assert_response :success
    assert_equal "tiktok", User.find_by(email: "phone@example.com").reference
  end

  test "Google sign-in from the claim CTA lands on the confirmation" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "claim-7001",
      info: { email: "googlefan@example.com", name: "Google Fan" }
    )
    get landing_page_path("tiktok")

    post "/auth/google_oauth2?#{{ return_to: @claimed, age_attestation: 1 }.to_query}"
    follow_redirect! # → the callback

    assert_redirected_to @claimed
    assert_equal "tiktok", User.find_by(email: "googlefan@example.com").reference
  end

  test "Google sign-in with an off-site return_to falls back to the usual landing" do
    OmniAuth.config.mock_auth[:google_oauth2] = OmniAuth::AuthHash.new(
      provider: "google_oauth2", uid: "claim-7002",
      info: { email: "googlefan2@example.com", name: "Google Fan Two" }
    )

    post "/auth/google_oauth2?#{{ return_to: "//evil.example", age_attestation: 1 }.to_query}"
    follow_redirect!

    refute_match(/evil\.example/, response.location.to_s)
  end
end
