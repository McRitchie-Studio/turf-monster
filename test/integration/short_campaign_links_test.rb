require "test_helper"

# [integration] Campaign short links end to end: /l/<token> → the target
# tagged ?r=<reference>, one click counted on the landing, and every other
# tenant of /l/ (magic links, user referrals, the /lp fallback) unchanged.
# Also the /admin/short_links CRUD.
class ShortCampaignLinksTest < ActionDispatch::IntegrationTest
  include RackAttackClock

  BROWSER = { "User-Agent" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 " \
                              "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1" }.freeze

  setup do
    @tt = CampaignLink.create!(token: "tt", target_path: "/turf-monster-v2", reference: "tiktok-bio")
  end

  # --- the click ----------------------------------------------------------------

  test "GET /l/tt redirects 302 to the target tagged r=tiktok-bio" do
    get "/l/tt", headers: BROWSER.dup
    assert_response :found
    assert_redirected_to "/turf-monster-v2?r=tiktok-bio"
  end

  test "a first-time browser's click counts exactly once, on the landing, and sets first touch" do
    assert_no_difference("ReferralVisit.count", "the /l/ hop records nothing") do
      get "/l/tt", headers: BROWSER.dup
    end

    assert_difference("ReferralVisit.count", 1, "the landing records at once: the hop set the visitor cookie") do
      follow_redirect!(headers: BROWSER.dup)
    end
    assert_response :success
    visit = ReferralVisit.sole
    assert_equal "tiktok-bio", visit.reference
    assert_equal "/turf-monster-v2", visit.landing_path
    assert_equal "tiktok-bio", cookies[:reference]
    assert cookies[ReferralVisitTracking::PENDING_COOKIE].blank?, "nothing left parked to count twice"

    assert_no_difference("ReferralVisit.count", "a second click the same day is the same visitor") do
      get "/l/tt", headers: BROWSER.dup
      follow_redirect!(headers: BROWSER.dup)
      get contests_path, headers: BROWSER.dup
    end
  end

  test "the short link's own utm query rides through to the landing" do
    get "/l/tt", params: { utm_medium: "bio" }, headers: BROWSER.dup
    assert_redirected_to "/turf-monster-v2?utm_medium=bio&r=tiktok-bio"
    follow_redirect!(headers: BROWSER.dup)
    assert_equal "bio", ReferralVisit.sole.utm_medium
  end

  test "the token is found in any case" do
    get "/l/TT", headers: BROWSER.dup
    assert_redirected_to "/turf-monster-v2?r=tiktok-bio"
  end

  test "a disabled link lands on the home page untagged and counts nothing" do
    @tt.disable!
    get "/l/tt", headers: BROWSER.dup
    assert_redirected_to root_path
    follow_redirect!(headers: BROWSER.dup)
    assert_equal 0, ReferralVisit.count
    assert_nil cookies[:reference].presence
  end

  test "an earlier first touch is not overwritten by the short link" do
    get root_path, params: { r: "ig-story" }, headers: BROWSER.dup
    get "/l/tt", headers: BROWSER.dup
    follow_redirect!(headers: BROWSER.dup)
    assert_equal "ig-story", cookies[:reference]
    assert_includes ReferralVisit.pluck(:reference), "tiktok-bio", "the click still counts under its own name"
  end

  # --- the other tenants of /l/ ----------------------------------------------------

  test "a campaign wins over a landing page given the same slug later" do
    LandingPage.create!(name: "Shadowed", slug: "tt", active: false)
    get "/l/tt", headers: BROWSER.dup
    assert_redirected_to "/turf-monster-v2?r=tiktok-bio"
  end

  test "an unknown /l/<slug> still falls back to its landing page" do
    get "/l/#{landing_pages(:launch).slug}"
    assert_response :moved_permanently
    assert_redirected_to landing_page_path(landing_pages(:launch).slug)
  end

  test "an unknown /l/<token> with no landing page is still the invalid-link bounce" do
    get "/l/no-such-thing"
    assert_redirected_to signin_path
  end

  test "a magic link still renders its inert confirm interstitial" do
    token = Studio::Link.create_magic_link(email: "ml-campaign@mcritchie.studio", age_attested: true).token
    get "/l/#{token}"
    assert_response :success
    assert Studio::Link.find_by(token: token).consumed_at.nil?, "GET never burns"

    assert_difference("User.count", 1) { post link_consume_path(token: token) }
  end

  test "a user's referral link still sets the inviter cookie and redirects" do
    link = Studio::Link.referral_for(users(:jordan))
    get "/l/#{link.token}"
    assert_redirected_to root_path
    assert_equal(users(:jordan).slug.presence || link.token, cookies[:reference])
  end

  test "a campaign token cannot be consumed as a magic link" do
    assert_no_difference("User.count") { post link_consume_path(token: "tt") }
    assert_nil session[:user_id]
  end

  # --- the long spelling and Coinflow ------------------------------------------------

  test "?reference= links keep working beside ?r=" do
    cookies[ReferralVisitTracking::VISITOR_COOKIE.to_s] = "11111111-2222-4333-8444-555555555555"
    get turf_monster_v2_path, params: { reference: "tiktok-video-1007" }, headers: BROWSER.dup
    assert_equal ["tiktok-video-1007"], ReferralVisit.pluck(:reference)
    assert_equal "tiktok-video-1007", cookies[:reference]
  end

  test "a coinflow checkout return is neither a click nor first-touch attribution" do
    log_in_as(users(:jordan))
    cookies[ReferralVisitTracking::VISITOR_COOKIE.to_s] = "11111111-2222-4333-8444-555555555555"
    get tokens_buy_path, params: { coinflow: "return", reference: "purchase-abc" }, headers: BROWSER.dup
    assert_equal 0, ReferralVisit.count
    assert_nil cookies[:reference].presence
  end

  # --- admin ---------------------------------------------------------------------

  test "the admin is admin-only" do
    get admin_short_links_path
    assert_redirected_to signin_path

    log_in_as(users(:jordan))
    get admin_short_links_path
    assert_redirected_to root_path
    post admin_short_links_path, params: { campaign_link: { token: "x1", target_path: "/", reference: "x" } }
    assert_nil CampaignLink.find_by(token: "x1")
  end

  test "the list shows each link with its full short URL and its clicks" do
    get "/l/tt", headers: BROWSER.dup
    follow_redirect!(headers: BROWSER.dup)

    log_in_as(users(:alex))
    get admin_short_links_path
    assert_response :success
    assert_select "[data-short-link='tt'] [data-copy-text=?]", "http://www.example.com/l/tt"
    assert_select "[data-short-link='tt'] [data-clicks]", text: "1"
    assert_select "[data-short-link='tt']", text: /tiktok-bio/
  end

  test "an admin creates a link" do
    log_in_as(users(:alex))
    post admin_short_links_path, params: { campaign_link: { token: "XB", target_path: "/contests", reference: "x-bio" } }
    assert_redirected_to admin_short_links_path

    link = CampaignLink.find_by(token: "xb")
    assert_equal "/contests", link.target_path
    assert_equal "x-bio", link.reference
  end

  test "an invalid create re-renders the form with its errors" do
    log_in_as(users(:alex))
    post admin_short_links_path, params: { campaign_link: { token: "new", target_path: "https://evil.example", reference: "" } }
    assert_response :unprocessable_entity
    assert_select "[role=alert] li", text: "Name is reserved"
    assert_select "[role=alert] li", text: /\AGoes to must be a path on this site/
  end

  test "an admin edits a link, renaming it" do
    log_in_as(users(:alex))
    get edit_admin_short_link_path(@tt)
    assert_response :success

    patch admin_short_link_path(@tt), params: { campaign_link: { token: "tiktok", target_path: "/", reference: "tiktok-bio-2" } }
    assert_redirected_to admin_short_links_path
    @tt.reload
    assert_equal ["tiktok", "/", "tiktok-bio-2"], [@tt.token, @tt.target_path, @tt.reference]
  end

  test "a failed rename keeps the form posting to the link's saved token" do
    log_in_as(users(:alex))
    patch admin_short_link_path(@tt), params: { campaign_link: { token: "Bad Name", target_path: "/", reference: "x" } }
    assert_response :unprocessable_entity
    assert_select "form[action=?]", admin_short_link_path("tt")
  end

  test "an admin disables and re-enables a link" do
    log_in_as(users(:alex))
    patch toggle_admin_short_link_path(@tt)
    assert_not @tt.reload.active?
    patch toggle_admin_short_link_path(@tt)
    assert @tt.reload.active?
  end

  test "the Link Hub links to the short links admin" do
    log_in_as(users(:alex))
    get admin_hub_path
    assert_select "a[href=?]", admin_short_links_path, count: 1
  end
end
