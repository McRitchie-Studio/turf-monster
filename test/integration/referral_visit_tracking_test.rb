require "test_helper"

# [integration] Sitewide click counting (ReferralVisitTracking) and the
# /admin/referrals report behind it.
class ReferralVisitTrackingTest < ActionDispatch::IntegrationTest
  BROWSER = { "User-Agent" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 " \
                              "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1" }.freeze

  VISITOR = "11111111-2222-4333-8444-555555555555".freeze

  # A browser that has been here before: it sends the visitor cookie back.
  def returning_visitor(id = VISITOR)
    cookies[ReferralVisitTracking::VISITOR_COOKIE.to_s] = id
  end

  test "a GET with ?reference=tiktok records one click, and a refresh records none" do
    returning_visitor
    assert_difference "ReferralVisit.count", 1 do
      get root_path, params: { reference: "tiktok" }, headers: BROWSER.dup
    end
    visit = ReferralVisit.sole
    assert_equal "tiktok", visit.reference
    assert_equal "/", visit.landing_path
    assert_equal VISITOR, visit.visitor_id

    assert_no_difference "ReferralVisit.count" do
      get root_path, params: { reference: "tiktok" }, headers: BROWSER.dup
      get root_path, params: { reference: "TikTok" }, headers: BROWSER.dup
    end
  end

  # The click is parked until the visitor cookie comes back, so a client that
  # keeps no cookies writes nothing however often it asks.
  test "a first click without the visitor cookie writes nothing until the cookie comes back" do
    assert_no_difference "ReferralVisit.count" do
      get root_path, params: { reference: "tiktok", utm_source: "TikTok" }, headers: BROWSER.dup
    end
    assert cookies[ReferralVisitTracking::VISITOR_COOKIE].present?, "the visitor cookie is set"
    assert cookies[ReferralVisitTracking::PENDING_COOKIE].present?, "the click is parked"

    assert_difference "ReferralVisit.count", 1 do
      get contests_path, headers: BROWSER.dup
    end
    visit = ReferralVisit.sole
    assert_equal "tiktok", visit.reference
    assert_equal "/", visit.landing_path, "the parked click keeps the page it landed on"
    assert_equal "tiktok", visit.utm_source
    assert cookies[ReferralVisitTracking::PENDING_COOKIE].blank?, "the parked click is spent"

    assert_no_difference("ReferralVisit.count") { get root_path, headers: BROWSER.dup }
  end

  test "a client that never returns cookies writes nothing" do
    assert_no_difference "ReferralVisit.count" do
      5.times do
        open_session { |s| s.get root_path, params: { reference: "spam-#{rand(1000)}" }, headers: BROWSER.dup }
      end
    end
  end

  test "a parked click is dropped when a crawler brings the cookies back" do
    get root_path, params: { reference: "tiktok" }, headers: BROWSER.dup
    assert_no_difference("ReferralVisit.count") { get root_path, headers: { "User-Agent" => "Googlebot/2.1" } }
    assert cookies[ReferralVisitTracking::PENDING_COOKIE].blank?
  end

  # Prepended ahead of the auth gate: a link to a signed-in page that bounces
  # a stranger to /signin was still a click.
  test "the click is counted even when the page redirects to sign-in" do
    returning_visitor
    assert_difference "ReferralVisit.count", 1 do
      get account_path, params: { reference: "tiktok-bio" }, headers: BROWSER.dup
    end
    assert_response :redirect
  end

  test "a first-time visitor's click is counted on the sign-in bounce" do
    assert_difference "ReferralVisit.count", 1 do
      get account_path, params: { reference: "tiktok-bio" }, headers: BROWSER.dup
      follow_redirect!(headers: BROWSER.dup)
    end
    assert_equal "/account", ReferralVisit.sole.landing_path
  end

  test "a page carrying a bearer token is never recorded as a landing path" do
    returning_visitor
    assert_no_difference "ReferralVisit.count" do
      get "/magic_link/secret-token-value", params: { reference: "mailer" }, headers: BROWSER.dup
      get "/email_verification/secret-token-value", params: { reference: "mailer" }, headers: BROWSER.dup
      get "/account/wallet/export/secret-token-value", params: { reference: "mailer" }, headers: BROWSER.dup
      get "/l/secret-token-value", params: { reference: "mailer" }, headers: BROWSER.dup
    end
  end

  # Rack::Attack.referral_visit_allowed?: a client making up a new visitor
  # cookie per request is capped per address, and the page is still served.
  test "clicks past the per-address limit are not recorded and the page still answers" do
    prior_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.enabled = true
    limit = Rack::Attack::REFERRAL_VISIT_LIMIT

    assert_difference "ReferralVisit.count", limit do
      (limit + 5).times do |n|
        returning_visitor(format("00000000-0000-4000-8000-%012d", n))
        get root_path, params: { reference: "tiktok" }, headers: BROWSER.dup
        assert_includes [200, 302], response.status, "the page answers as it would without tracking"
      end
    end

    assert_difference("ReferralVisit.count", 1, "another address is counted on its own") do
      returning_visitor(format("00000000-0000-4000-9000-%012d", 1))
      get root_path, params: { reference: "tiktok" }, headers: BROWSER.merge("REMOTE_ADDR" => "203.0.113.50")
    end
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.cache.store = prior_store
  end

  # The cap fails open on a Redis outage, as every rack-attack rule does
  # (config/initializers/rack_attack.rb, "Cache outage").
  test "with Redis down, clicks past the per-address limit are recorded and the page still answers" do
    limit = Rack::Attack::REFERRAL_VISIT_LIMIT

    RedisCacheOutage.with_rack_attack do |swallowed|
      assert_difference "ReferralVisit.count", limit + 5 do
        (limit + 5).times do |n|
          returning_visitor(format("00000000-0000-4000-a000-%012d", n))
          get root_path, params: { reference: "tiktok" }, headers: BROWSER.dup
          assert_includes [200, 302], response.status
        end
      end
      refute_empty swallowed, "the store must actually have failed"
    end
  end

  test "a page view with no reference records nothing and sets no visitor cookie" do
    assert_no_difference("ReferralVisit.count") { get root_path, headers: BROWSER.dup }
    assert_nil cookies[ReferralVisitTracking::VISITOR_COOKIE]
  end

  test "the vanity /tiktok counts once across its redirect hop" do
    assert_difference "ReferralVisit.count", 1 do
      get "/tiktok", headers: BROWSER.dup
      follow_redirect!(headers: BROWSER.dup)
    end
    assert_equal "tiktok", ReferralVisit.sole.reference
    assert_equal "/tiktok", ReferralVisit.sole.landing_path
  end

  test "a landing page counts under its slug" do
    returning_visitor
    page = landing_pages(:launch)
    assert_difference("ReferralVisit.count", 1) { get landing_page_path(page.slug), headers: BROWSER.dup }
    assert_equal page.slug, ReferralVisit.sole.reference
  end

  test "a landing page link that names its own reference counts under that name only" do
    returning_visitor
    page = landing_pages(:launch)
    assert_difference("ReferralVisit.count", 1) do
      get landing_page_path(page.slug), params: { reference: "tiktok-video-1007" }, headers: BROWSER.dup
    end
    assert_equal "tiktok-video-1007", ReferralVisit.sole.reference
  end

  test "link unfurlers, HEAD requests and admin paths do not count" do
    returning_visitor
    assert_no_difference "ReferralVisit.count" do
      get root_path, params: { reference: "tiktok" }, headers: { "User-Agent" => "facebookexternalhit/1.1" }
      head root_path, params: { reference: "tiktok" }, headers: BROWSER.dup
      get admin_referrals_path, params: { reference: "tiktok" }, headers: BROWSER.dup
    end
  end

  test "a coinflow checkout return's payment reference is not a click" do
    returning_visitor
    assert_no_difference "ReferralVisit.count" do
      get tokens_buy_path, params: { coinflow: "return", reference: "cfp-123" }, headers: BROWSER.dup
    end
  end

  test "a database failure while counting does not break the page" do
    returning_visitor
    ReferralVisit.stub(:insert, ->(*) { raise ActiveRecord::StatementInvalid, "boom" }) do
      get root_path, params: { reference: "tiktok" }, headers: BROWSER.dup
    end
    assert_includes [200, 302], response.status, "the page answers as it would without tracking"
    assert_equal 0, ReferralVisit.count
  end

  test "an email registration stamps the reference cookie onto the new user" do
    get root_path, params: { reference: "tiktok-bio" }, headers: BROWSER.dup
    post signup_path, params: { user: { email: "cookie-ref@mcritchie.studio" }, age_attestation: "1" }
    assert_equal "tiktok-bio", User.find_by(email: "cookie-ref@mcritchie.studio")&.reference
  end

  # --- the report ---------------------------------------------------------------

  test "the report is admin-only" do
    get admin_referrals_path
    assert_redirected_to signin_path

    log_in_as(users(:jordan))
    get admin_referrals_path
    assert_redirected_to root_path
  end

  test "the report shows clicks and account signups per reference for an admin" do
    User.update_all(reference: nil)
    returning_visitor
    get root_path, params: { reference: "tiktok" }, headers: BROWSER.dup
    users(:sam).update_columns(reference: "TikTok", created_at: 1.day.ago)

    log_in_as(users(:alex))
    get admin_referrals_path, params: { days: "7" }

    assert_response :success
    assert_select "[data-reference-row='tiktok'] [data-cell='clicks']", text: "1"
    assert_select "[data-reference-row='tiktok'] [data-cell='visitors']", text: "1"
    assert_select "[data-reference-row='tiktok'] [data-cell='accounts']", text: "1"
    assert_select "[data-reference-row='tiktok'] [data-cell='account-rate']", text: "100.0%"
    assert_select "[data-referral-window] a[aria-current='page']", text: "7 days"
  end

  test "the per-day table opens for one reference" do
    returning_visitor
    get root_path, params: { reference: "tiktok" }, headers: BROWSER.dup
    log_in_as(users(:alex))
    get admin_referrals_path, params: { days: "7", reference: "TikTok" }

    assert_response :success
    assert_select "[data-referral-daily='tiktok'] tbody tr", count: 7
    assert_select "[data-referral-daily='tiktok'] tr[data-day='#{Date.current.iso8601}'] td", text: "1"
  end

  test "the Link Hub links to the report" do
    log_in_as(users(:alex))
    get admin_hub_path
    assert_select "a[href=?]", admin_referrals_path, count: 1
  end
end
