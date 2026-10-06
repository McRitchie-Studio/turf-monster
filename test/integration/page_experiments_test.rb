require "test_helper"

# [integration] Page A/B testing end to end: a bound short link assigns a
# variant and names it in the URL, the page renders that variant's copy and
# keeps it on return, the visit and the CTA taps are counted per variant, the
# conversions (a notify-me signup, a new account) carry it, bots are left out,
# and the admin report is admin-only with the right numbers.
class PageExperimentsTest < ActionDispatch::IntegrationTest
  include PageExperimentFixture

  BROWSER = { "User-Agent" => "Mozilla/5.0 (iPhone; CPU iPhone OS 17_5 like Mac OS X) AppleWebKit/605.1.15 " \
                              "(KHTML, like Gecko) Version/17.5 Mobile/15E148 Safari/604.1" }.freeze
  # A link unfurler (served the engine's slim preview page) and a crawler
  # (served the full page): both are bots to the experiment.
  BOT = { "User-Agent" => "facebookexternalhit/1.1 (+http://www.facebook.com/externalhit_uatext.php)" }.freeze
  CRAWLER = { "User-Agent" => "Mozilla/5.0 (compatible; Bytespider; spider-feedback@bytedance.com)" }.freeze
  COOKIE = "exp_turf-monster-v2".freeze

  setup do
    @experiment = create_page_experiment
    @tt = CampaignLink.create!(token: "tt", target_path: "/turf-monster-v2", reference: "tiktok-bio",
                               experiment_slug: "turf-monster-v2")
  end

  def root_node
    css_select('[data-test="turf-monster-v2"]').first
  end

  def headline
    css_select('[data-test="v2-headline"] span').map { |s| s.text.strip }
  end

  def visit_page(v: nil, headers: BROWSER)
    get turf_monster_v2_path, params: { v: v }.compact, headers: headers.dup
    assert_response :success
  end

  def beacon(event, experiment: "turf-monster-v2", headers: BROWSER)
    post experiment_events_path, params: { experiment: experiment, event: event }, headers: headers.dup
    assert_response :no_content
  end

  # --- the short link -----------------------------------------------------------------

  test "GET /l/tt assigns a variant, stores it, and redirects with ?r= and ?v=" do
    get "/l/tt", headers: BROWSER.dup
    assert_response :found
    key = cookies[COOKIE]
    assert_includes %w[control fantasy-football], key
    assert_redirected_to "/turf-monster-v2?r=tiktok-bio&v=#{key}"
  end

  test "the landing renders the assigned variant, counts one visit for it, and keeps it on return" do
    cookies[COOKIE] = "fantasy-football"
    get "/l/tt", headers: BROWSER.dup
    assert_redirected_to "/turf-monster-v2?r=tiktok-bio&v=fantasy-football"

    assert_difference("ExperimentEvent.count", 1) { follow_redirect!(headers: BROWSER.dup) }
    assert_equal "fantasy-football", root_node["data-variant"]
    assert_equal "turf-monster-v2", root_node["data-experiment"]
    assert_equal "/experiment-events", root_node["data-experiment-beacon"]
    assert_equal ["NFL Team", "Fantasy", "Football"], headline
    assert_select "title", "Turf Monster — NFL Team Fantasy Football"

    visit = ExperimentEvent.sole
    assert_equal %w[turf-monster-v2 fantasy-football visit tiktok-bio],
                 [visit.experiment_slug, visit.variant_key, visit.event, visit.reference]
    assert_equal cookies[ReferralVisitTracking::VISITOR_COOKIE], visit.visitor_id

    # The same visitor again, through the link and straight to the page: same
    # variant, no second count today.
    assert_no_difference("ExperimentEvent.count") do
      get "/l/tt", headers: BROWSER.dup
      assert_redirected_to "/turf-monster-v2?r=tiktok-bio&v=fantasy-football"
      follow_redirect!(headers: BROWSER.dup)
      visit_page
    end
    assert_equal "fantasy-football", root_node["data-variant"]
  end

  test "a visitor's draw is sticky across many returns" do
    get "/l/tt", headers: BROWSER.dup
    first = cookies[COOKIE]
    5.times do
      get "/l/tt", headers: BROWSER.dup
      assert_redirected_to "/turf-monster-v2?r=tiktok-bio&v=#{first}"
    end
  end

  test "a link with no experiment bound adds no ?v=" do
    CampaignLink.create!(token: "ig", target_path: "/turf-monster-v2", reference: "ig-bio")
    get "/l/ig", headers: BROWSER.dup
    assert_redirected_to "/turf-monster-v2?r=ig-bio"
  end

  test "a bot following the link gets no variant in the URL and no cookie" do
    get "/l/tt", headers: BOT.dup
    assert_redirected_to "/turf-monster-v2?r=tiktok-bio"
    assert cookies[COOKIE].blank?
  end

  test "a paused experiment's link adds no ?v=, and the page is unchanged" do
    @experiment.update!(active: false)
    get "/l/tt", headers: BROWSER.dup
    assert_redirected_to "/turf-monster-v2?r=tiktok-bio"
    follow_redirect!(headers: BROWSER.dup)
    assert_nil root_node["data-variant"]
    assert_equal ["Pick 6 teams.", "Stack points.", "Get paid."], headline
    assert_equal 0, ExperimentEvent.count
  end

  # --- the page -----------------------------------------------------------------------

  test "the control renders the page's own copy" do
    visit_page(v: "control")
    assert_equal "control", root_node["data-variant"]
    assert_equal ["Pick 6 teams.", "Stack points.", "Get paid."], headline
    assert_select '[data-test="v2-subhead-desktop"]', /Choose 6 NFL teams/
    assert_select "title", "Turf Monster — Pick 6 NFL Teams, Stack Points"
  end

  test "an explicit ?v= wins over the cookie and re-pins the visitor" do
    cookies[COOKIE] = "control"
    visit_page(v: "fantasy-football")
    assert_equal "fantasy-football", root_node["data-variant"]
    assert_select '[data-test="v2-subhead-desktop"]', "Draft 6 NFL teams, not players. Desktop variant subhead."
    assert_select '[data-test="v2-subhead-mobile"]', "Draft 6 NFL teams. Mobile variant subhead."
    assert_equal "fantasy-football", cookies[COOKIE]
  end

  test "an organic first visit is assigned and stored; its visit is counted by the beacon it then sends" do
    assert_no_difference("ExperimentEvent.count", "no visitor cookie came back yet") { visit_page }
    key = cookies[COOKIE]
    assert_includes %w[control fantasy-football], key
    assert_equal key, root_node["data-variant"]

    assert_difference("ExperimentEvent.count", 1) { beacon("visit") }
    assert_equal [key, "visit"], ExperimentEvent.sole.then { |e| [e.variant_key, e.event] }
    assert_no_difference("ExperimentEvent.count", "the server folds the render and the beacon") { visit_page }
  end

  test "a bot sees the control, gets no cookie and no beacon, and is never counted" do
    visit_page(headers: CRAWLER)
    assert_equal "control", root_node["data-variant"]
    assert_nil root_node["data-experiment-beacon"], "a bot's page sends no beacon"
    assert cookies[COOKIE].blank?
    cookies[ReferralVisitTracking::VISITOR_COOKIE] = SecureRandom.uuid
    cookies[COOKIE] = "fantasy-football"
    visit_page(headers: CRAWLER)
    beacon("play", headers: CRAWLER)
    assert_equal 0, ExperimentEvent.count
  end

  test "the CTAs carry their beacon names" do
    visit_page
    assert_select '[data-test="v2-hero-cta"][data-cta="play"]'
    assert_select '[data-test="v2-closing-cta"][data-cta="play"]'
    assert_select 'form[data-cta-submit="notify"]'
  end

  # --- the beacon ---------------------------------------------------------------------

  test "a CTA tap is recorded once per visitor per day, under the visitor's own variant" do
    visit_page(v: "fantasy-football")
    assert_difference("ExperimentEvent.where(event: 'cta:play').count", 1) do
      beacon("play")
      beacon("play")
    end
    beacon("notify")
    beacon("watch_live")
    assert_equal %w[cta:notify cta:play cta:watch_live], ExperimentEvent.order(:event).pluck(:event),
                 "a first page view counts no visit itself (no visitor cookie came back yet); the taps all count"
    assert_equal ["fantasy-football"], ExperimentEvent.distinct.pluck(:variant_key)
  end

  test "the beacon trusts the cookie, not the client: no cookie or an unknown event records nothing" do
    beacon("play") # never assigned
    visit_page(v: "control")
    beacon("bogus")
    beacon("play", experiment: "no-such-experiment")
    assert_equal 0, ExperimentEvent.where.not(event: "visit").count
  end

  # allow_forgery_protection is off in the test env (drop_signups_controller_test
  # explains), so this pins the wiring: nothing skips the CSRF check.
  test "CSRF verification is not skipped for the beacon" do
    callbacks = ExperimentEventsController._process_action_callbacks.select { |c| c.kind == :before }
    assert callbacks.any? { |c| c.filter == :verify_authenticity_token }
  end

  # --- conversions ----------------------------------------------------------------------

  test "a notify-me signup records the variant" do
    visit_page(v: "fantasy-football")
    post drop_signups_path, params: { email: "fan@example.com" }, headers: { "Accept" => "application/json" }.merge(BROWSER)
    assert_response :success
    signup = DropSignup.find_by!(email: "fan@example.com")
    assert_equal %w[turf-monster-v2 fantasy-football], [signup.experiment_slug, signup.variant_key]
  end

  test "a signup from a visitor in no experiment records none" do
    post drop_signups_path, params: { email: "plain@example.com" }, headers: { "Accept" => "application/json" }
    assert_nil DropSignup.find_by!(email: "plain@example.com").experiment_slug
  end

  test "a new account made by magic link records the variant" do
    visit_page(v: "control")
    link = Studio::Link.create_magic_link(email: "newfan@example.com", age_attested: true)
    post magic_link_consume_path(token: link.token)
    user = User.find_by!(email: "newfan@example.com")
    assert_equal %w[turf-monster-v2 control], [user.experiment_slug, user.variant_key]
  end

  # --- the admin ------------------------------------------------------------------------

  test "the report is admin-only" do
    get admin_experiments_path
    refute response.successful?
    log_in_as(users(:jordan))
    get admin_experiments_path
    refute response.successful?
    get admin_experiment_path("turf-monster-v2")
    refute response.successful?
  end

  test "the report shows each arm's visitors, taps and signups" do
    visit_page(v: "fantasy-football")
    beacon("visit")
    beacon("play")
    post drop_signups_path, params: { email: "fan@example.com" }, headers: { "Accept" => "application/json" }.merge(BROWSER)

    log_in_as(users(:alex))
    get admin_experiment_path("turf-monster-v2")
    assert_response :success
    assert_select '[data-variant-row="fantasy-football"] [data-cell="visitors"]', "1"
    assert_select '[data-variant-row="fantasy-football"] [data-cell="cta-play"]', /\A\s*1\b/
    assert_select '[data-variant-row="fantasy-football"] [data-cell="email"]', /\A\s*1\b/
    assert_select '[data-variant-row="control"] [data-cell="visitors"]', "0"
    assert_select '[data-variant-row="fantasy-football"] [data-cell="significance"]', /Not significant yet/

    get admin_experiments_path
    assert_select '[data-experiment="turf-monster-v2"] [data-variant-row="fantasy-football"] [data-cell="visitors"]', "1"
  end

  test "an admin creates an experiment with its variants, and edits one" do
    log_in_as(users(:alex))
    get new_admin_experiment_path
    assert_response :success
    post admin_experiments_path, params: { page_experiment: {
      slug: "rules-v1", name: "Rules page title", page_path: "/turf-monster-v1", active: "1",
      variants_attributes: { "0" => { key: "control", weight: "1", position: "0" },
                             "1" => { key: "short", weight: "3", position: "1", headline: "Six teams.\nBig points." },
                             "2" => { key: "", weight: "0", position: "2" } }
    } }
    experiment = PageExperiment.find_by!(slug: "rules-v1")
    assert_redirected_to admin_experiment_path("rules-v1")
    assert_equal [%w[control 1], %w[short 3]], experiment.variants.map { |v| [v.key, v.weight.to_s] }

    variant = experiment.variants.find_by!(key: "short")
    patch admin_experiment_path("rules-v1"), params: { page_experiment: {
      active: "0", variants_attributes: { "0" => { id: variant.id, weight: "1" } }
    } }
    assert_redirected_to admin_experiment_path("rules-v1")
    refute experiment.reload.active?
    assert_equal 1, variant.reload.weight
  end

  test "an invalid experiment re-renders the form with its errors" do
    log_in_as(users(:alex))
    post admin_experiments_path, params: { page_experiment: {
      slug: "lonely", name: "x", page_path: "/turf-monster-v1",
      variants_attributes: { "0" => { key: "only", weight: "1" } }
    } }
    assert_response :unprocessable_entity
    assert_select "[role=alert]", /at least two/
  end

  test "an admin binds a short link to an experiment" do
    log_in_as(users(:alex))
    get edit_admin_short_link_path("tt")
    assert_select 'select[name="campaign_link[experiment_slug]"] option[selected][value="turf-monster-v2"]'
    patch admin_short_link_path("tt"), params: { campaign_link: { experiment_slug: "" } }
    assert_nil @tt.reload.experiment_slug
    patch admin_short_link_path("tt"), params: { campaign_link: { experiment_slug: "nope" } }
    assert_response :unprocessable_entity
  end
end
