require "test_helper"

# [integration] The friendly not-found page (task turf-adopts-not-found-page): a
# lost visitor gets a 404 with Turf's name and a button home, never a 200 or a
# redirect. config.exceptions_app is guarded (config/application.rb), so these read
# whichever engine is locked: the engine page in Turf's layout, or the branded
# public/404.html (same words, same data-test hooks). The test env hides
# exceptions, so each request runs with production's exception settings.
#
# It also proves what each of Turf's global before_actions does on the page
# (config/initializers/not_found_page.rb): the skipped ones never run there, and
# the kept ones cannot turn the 404 into anything else.
class NotFoundPageTest < ActionDispatch::IntegrationTest
  ENGINE_PAGE = defined?(Studio::ExceptionsApp)

  BROWSER = { "User-Agent" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 " \
                              "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1" }.freeze
  # Safari 14: below allow_browser's :modern, what Apple's link-preview fetcher sends.
  OLD_SAFARI = { "User-Agent" => "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 " \
                                 "(KHTML, like Gecko) Version/14.0 Safari/605.1.15" }.freeze
  VISITOR = "11111111-2222-4333-8444-555555555555".freeze

  def with_production_exceptions
    config = Rails.application.env_config
    saved = config.slice("action_dispatch.show_exceptions", "action_dispatch.show_detailed_exceptions")
    config["action_dispatch.show_exceptions"] = :all
    config["action_dispatch.show_detailed_exceptions"] = false
    yield
  ensure
    config.merge!(saved)
  end

  def get_lost(path, headers: BROWSER, **options)
    with_production_exceptions { get path, headers: headers.dup, **options }
  end

  # The page a lost visitor sees, on either engine: status 404, the friendly
  # words, Turf's name and one button back to Turf's root.
  def assert_friendly_page(engine: ENGINE_PAGE)
    assert_response :not_found
    assert_nil response.location, "never a redirect"
    assert_match %r{\Atext/html}, response.media_type
    assert_select "[data-test='not-found']", count: 1 do
      assert_select "h1", text: "This page isn’t here"
      assert_select "a[data-test='not-found-home'][href='/']", text: "Back to Turf Monster", count: 1
    end
    assert_select "title", "Page not found · Turf Monster"
    if engine
      assert_select "main [data-test='not-found']", count: 1
      assert_select "nav", minimum: 1, message: "Turf's navbar: the page sits in the layout"
      assert_select "img[data-studio-not-found-logo][src='/icon-192.png'][alt='Turf Monster']"
      assert_select "[data-static-404]", count: 0, message: "the engine page, not the static fallback"
    else
      assert_select "body[data-static-404]", count: 1
    end
  end

  # Counts perform_solana_preload, the navbar's on-chain warm-up that
  # preload_navbar_solana_data calls, without changing what it does.
  def counting_solana_preloads
    calls = []
    original = ApplicationController.instance_method(:perform_solana_preload)
    ApplicationController.define_method(:perform_solana_preload) do
      calls << request.path
      original.bind_call(self)
    end
    yield calls
  ensure
    ApplicationController.define_method(:perform_solana_preload, original)
    ApplicationController.send(:private, :perform_solana_preload)
  end

  test "an unknown address answers 404 with the friendly page and a home link to the root" do
    get_lost "/no-such-page"

    assert_friendly_page
  end

  test "a signed-out visitor gets the page, not a sign-in redirect" do
    get_lost "/no/such/page/either"

    assert_friendly_page
    assert_not response.redirect?
  end

  test "the skips are on the page's own callback chain and nowhere else" do
    skip "engine without Studio::NotFoundController" unless ENGINE_PAGE

    on_page = Studio::NotFoundController._process_action_callbacks.select { |c| c.kind == :before }.map(&:filter)
    skipped = %i[require_profile_completion preload_navbar_solana_data track_referral_visit capture_reference]
    kept = %i[verify_session_token set_current_context touch_last_seen refuse_parked_fiat_rail refuse_frozen_account_writes]

    assert_empty skipped & on_page, "the not-found page must not run these"
    assert_empty kept - on_page, "the not-found page keeps these"
    on_app = ApplicationController._process_action_callbacks.select { |c| c.kind == :before }.map(&:filter)
    assert_empty (skipped + kept) - on_app, "every other page still runs all of them"
  end

  test "a signed-in player with an incomplete profile gets the 404, not the profile redirect, and return_to is untouched" do
    user = users(:jordan)
    log_in_as(user)
    user.update_column(:username, nil)

    # The control: on a real page the filter does redirect and store the address.
    get contests_path, headers: BROWSER.dup
    assert_redirected_to complete_profile_account_path
    assert_equal contests_path, session[:return_to]

    get_lost "/no-such-page"

    assert_friendly_page
    assert_equal contests_path, session[:return_to], "a dead address is never stored as the place to come back to"
  end

  test "the navbar's Solana preload does not run on a 404" do
    log_in_as(users(:casey))
    assert users(:casey).solana_connected?

    counting_solana_preloads do |calls|
      # The control: a real HTML page warms the navbar.
      get contests_path, headers: BROWSER.dup
      assert_response :success
      assert_equal [contests_path], calls

      get_lost "/no-such-page"

      assert_friendly_page
      assert_equal [contests_path], calls, "a 404 must not reach the Solana warm-up"
    end
  end

  test "a dead link with ?r= records no click and seeds no attribution cookie" do
    cookies[ReferralVisitTracking::VISITOR_COOKIE.to_s] = VISITOR

    assert_no_difference "ReferralVisit.count" do
      get_lost "/no-such-page", params: { r: "tiktok" }
    end
    assert_friendly_page
    assert cookies[:reference].blank?, "capture_reference does not run on the page"
  end

  test "a click parked before a 404 stays parked and counts on the next real page" do
    assert_no_difference("ReferralVisit.count") { get root_path, params: { r: "tiktok" }, headers: BROWSER.dup }
    assert cookies[ReferralVisitTracking::PENDING_COOKIE].present?, "the click is parked"

    assert_no_difference("ReferralVisit.count") { get_lost "/no-such-page" }
    assert_friendly_page
    assert cookies[ReferralVisitTracking::PENDING_COOKIE].present?, "the 404 neither spends nor clears it"

    assert_difference("ReferralVisit.count", 1) { get contests_path, headers: BROWSER.dup }
    assert_equal "/", ReferralVisit.sole.landing_path
  end

  test "an old browser or a link-preview fetcher gets the page, not a 406" do
    get_lost "/no-such-page", headers: OLD_SAFARI

    assert_friendly_page
  end

  test "a stale session is still logged out on a 404, and the answer stays a 404" do
    user = users(:jordan)
    log_in_as(user)
    user.update_column(:session_token, SecureRandom.hex(32))

    get_lost "/no-such-page"

    # verify_session_token's sign-in redirect is thrown away by the exceptions app,
    # which serves the static last resort instead: still a 404, never a redirect.
    assert_friendly_page(engine: false)
  end

  test "a JSON request answers 404 JSON, not the HTML page" do
    get_lost "/no-such-page", headers: { "Accept" => "application/json" }

    assert_response :not_found
    assert_equal "application/json", response.media_type
    assert_equal({ "status" => 404, "error" => "Not Found" }, response.parsed_body)
    assert_not_includes response.body, "<html"
  end

  test "an unknown /api address keeps the API's own 404 body" do
    get_lost "/api/v1/no-such-resource", headers: { "Accept" => "application/json" }

    assert_response :not_found
    assert_equal "application/json", response.media_type
    assert_equal({ "error" => { "code" => "not_found", "message" => "No such resource." } }, response.parsed_body)
  end

  test "a page on Turf the visitor came from adds Go back" do
    get_lost "/no-such-page", headers: BROWSER.merge("Referer" => "http://www.example.com/contests")

    assert_friendly_page
    if ENGINE_PAGE
      assert_select "a[data-test='not-found-back'][href='/contests']", text: "Go back", count: 1
    else
      assert_select "[data-test='not-found-back']", count: 0
    end
  end

  test "the static last resort, public/404.html, carries the brand, the words and the home link" do
    page = Nokogiri::HTML(Rails.public_path.join("404.html").read)

    assert_equal "Page not found · Turf Monster", page.at_css("title").text
    assert page.at_css("body[data-static-404] [data-test='not-found']")
    assert_equal "This page isn’t here", page.at_css("h1").text
    home = page.at_css("a[data-test='not-found-home']")
    assert_equal "/", home["href"]
    assert_equal "Back to Turf Monster", home.text
    assert page.at_css("img[src='/icon-192.png'][alt='Turf Monster']"), "the navbar's mark"
    assert Rails.public_path.join("icon-192.png").exist?, "and the mark is there to load"
    assert_includes page.at_css("style").text, "prefers-color-scheme: dark"
    assert_empty page.css("script"), "the last resort runs nothing"
    assert_empty page.css("link[rel='stylesheet']"), "and loads nothing that could be missing"
  end
end
