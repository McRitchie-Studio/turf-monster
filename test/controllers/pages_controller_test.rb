require "test_helper"

class PagesControllerTest < ActionDispatch::IntegrationTest
  test "terms page renders without auth" do
    get terms_path
    assert_response :success
    assert_select "h1", /Terms of Service/
    assert_select "a[href=?]", privacy_path
  end

  test "privacy page renders without auth" do
    get privacy_path
    assert_response :success
    assert_select "h1", "Privacy Policy"
    assert_select "a[href=?]", terms_path
  end

  test "about page renders without auth" do
    get about_path
    assert_response :success
    assert_select "h1", "About Turf Totals"
    assert_select "a[href=?]", contact_path
  end

  test "contact page renders without auth" do
    get contact_path
    assert_response :success
    assert_select "h1", "Contact"
    assert_select "a[href=?]", about_path
  end

  test "global footer exposes the legitimacy + transparency links" do
    get terms_path
    assert_response :success
    # Footer is rendered in the application layout, so it appears on every
    # app page. These links are the site-legitimacy signals wallet scanners
    # look for; assert they are discoverable.
    %i[about_path contact_path privacy_path terms_path proof_of_reserves_path
       responsible_gaming_path state_eligibility_path].each do |helper|
      assert_select "footer a[href=?]", send(helper), { minimum: 1 },
        "footer should link to #{helper}"
    end
  end

  # ── underwriting compliance pages ─────────────────────────────────────────

  test "responsible gaming page renders without auth with the required resources" do
    get responsible_gaming_path
    assert_response :success
    assert_select "h1", /Responsible Gaming/
    # Problem-gambling resources underwriters check for.
    assert_match "1-800-GAMBLER", response.body
    assert_select "a[href*=?]", "ncpgambling.org"
    # Self-exclusion contact + commitment language.
    assert_select "a[href=?]", "mailto:alex@turfmonster.media"
    assert_match(/close your account/i, response.body)
  end

  # ── web3 onboarding guide ─────────────────────────────────────────────────

  test "getting started guide renders without auth with all five steps" do
    get getting_started_path
    assert_response :success
    assert_select "h1", "Getting Started"
    # The five steps, in order: Phantom → wallet → account → USDC → entry.
    assert_select "h2", /Download Phantom/
    assert_select "h2", /Create a new wallet/
    assert_select "h2", /Create your account/
    assert_select "h2", /Buy \$25 of USDC/
    assert_select "h2", /Sign in and enter a contest/
    # Official download link only — the guide must never point at a mirror.
    assert_select "a[href=?]", "https://phantom.com/download"
    # The operator's annotated walkthrough screenshots, one per setup beat.
    assert_select "section figure img[src*=?]", "guide/", minimum: 7
    # The fee expectation the operator verified: $25 purchase ≈ $20 after MoonPay fees.
    assert_match "MoonPay", response.body
    assert_match(/\$20 of USDC/, response.body)
    # Safety commitments: nobody asks for credentials; funnel into the app.
    assert_match(/never Turf Totals/i, response.body)
    assert_select "a[href=?]", signin_path
    assert_select "a[href=?]", proof_of_reserves_path
    assert_select "a[href=?]", responsible_gaming_path
  end

  test "state eligibility page renders the enforced GeoSetting list" do
    get state_eligibility_path
    assert_response :success
    assert_select "h1", /State Eligibility/
    # No GeoSetting row in fixtures → the page falls back to the defaults.
    GeoSetting::DEFAULT_BANNED_STATES.each do |code|
      assert_match(">#{code}<", response.body, "expected default-excluded state #{code}")
    end
  end

  test "state eligibility page renders from the LIVE GeoSetting row (no drift)" do
    GeoSetting.create!(app_name: Studio.app_name, enabled: true,
                       banned_states: %w[NY CA])
    get state_eligibility_path
    assert_response :success
    # The page must reflect the row enforcement reads — not a hardcoded list.
    assert_match "New York", response.body
    assert_match "California", response.body
    assert_no_match(/>WA</, response.body,
                    "a state absent from the live row must not be published")
  end

  test "terms page renders the anchored state-eligibility section from GeoSetting" do
    get terms_path
    assert_response :success
    assert_select "section#state-eligibility" do
      assert_select "h2", /State eligibility/
    end
    GeoSetting::DEFAULT_BANNED_STATES.each do |code|
      assert_match(">#{code}<", response.body, "terms should list excluded state #{code}")
    end
  end

  test "terms page referral copy uses the corrected grammar" do
    get terms_path
    assert_response :success
    assert_match "every two qualifying invitees earn one free entry", response.body
    assert_no_match(/invitees earns/, response.body)
  end

  test "terms page carries the refund and cancellation policy" do
    get terms_path
    assert_response :success
    assert_select "section#refunds" do
      assert_select "h2", /Refunds/i
    end
    assert_match(/cancelled before it locks/i, response.body)
  end
end
