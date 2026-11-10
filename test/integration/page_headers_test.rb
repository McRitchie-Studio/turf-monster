require "test_helper"
require "minitest/mock"

# [component] Turf's pages on the engine page header (task turf-standard-page-headers;
# Alex McRitchie 2026-11-08, "run the UI cleanup for all the apps, starting with Turf").
# Each page had a hand-rolled title: an h1 with its own sizes, often under a "← Back"
# link and beside a button row. Each now renders studio-engine's studio/_page_header:
# the crumb trail from config/initializers/studio_crumbs.rb where the back link stood,
# the title as main's one h1, and its buttons as the engine's kinds of control (menu,
# action), never actions_html. The table names every converted page, its title and
# the labels of its trail.
#
# The navbar's brand is the engine's h1 unless the page carries its own (layouts/_navbar,
# brand_heading), so the one-h1 rule here is main's: the page's own outline has exactly one h1, the header's.
class PageHeadersTest < ActionDispatch::IntegrationTest
  ROW = ".page-header".freeze
  KINDS = %w[page-header-menu page-header-action page-header-tools].freeze
  ADMIN = "Admin".freeze

  setup do
    log_in_as(users(:alex))
    # The admin tables link each row by slug; a fixture user carries none.
    User.where(slug: nil).find_each { |u| u.update_column(:slug, "user-#{u.id}") }
    @contest = contests(:one)
    @slate = slates(:one)
    @landing_page = landing_pages(:launch)
    @error_log = ErrorLog.capture!(RuntimeError.new("header test boom"))
    @outbound = OutboundRequest.create!(service: "stripe", status_code: 200)
    @experiment = PageExperiment.create!(slug: "header-exp", name: "Header Exp", page_path: "/turf-monster-v2",
                                         variants_attributes: [ { key: "a" }, { key: "b" } ])
  end

  # name => [path, the h1's text, the trail's ancestor labels (root first)]
  def pages
    {
      # Admin, under the Link Hub.
      "link hub" => [ admin_hub_path, "Link Hub", [] ],
      "dashboard" => [ admin_dashboard_path, "Dashboard", [ ADMIN ] ],
      "users" => [ admin_users_path, "Users", [ ADMIN ] ],
      "navbar review" => [ admin_navbar_path, "Navbar Review", [ ADMIN ] ],
      "level badges" => [ admin_level_badges_path, "Level Badges", [ ADMIN ] ],
      "schema" => [ admin_schema_path, "Database Schema", [ ADMIN ] ],
      "goal console" => [ admin_scoring_path, "Goal Console", [ ADMIN ] ],
      "error logs" => [ admin_error_logs_path, "Error Logs", [ ADMIN ] ],
      "error log" => [ admin_error_log_path(@error_log.slug), "header test boom", [ ADMIN, "Error Logs" ] ],
      "outbound requests" => [ admin_outbound_requests_path, "Outbound Requests", [ ADMIN ] ],
      "outbound request" => [ admin_outbound_request_path(@outbound), "Outbound Request ##{@outbound.id}", [ ADMIN, "Outbound Requests" ] ],
      "experiments" => [ admin_experiments_path, "Experiments", [ ADMIN ] ],
      "experiment" => [ admin_experiment_path(@experiment.slug), "Header Exp", [ ADMIN, "Experiments" ] ],
      "new experiment" => [ new_admin_experiment_path, "New Experiment", [ ADMIN, "Experiments" ] ],
      "edit experiment" => [ edit_admin_experiment_path(@experiment.slug), "Edit Header Exp", [ ADMIN, "Experiments" ] ],
      "landing pages" => [ admin_landing_pages_path, "Landing Pages", [ ADMIN ] ],
      "new landing page" => [ new_admin_landing_page_path, "New Landing Page", [ ADMIN, "Landing Pages" ] ],
      "edit landing page" => [ edit_admin_landing_page_path(@landing_page), "Edit Landing Page", [ ADMIN, "Landing Pages" ] ],
      "short links" => [ admin_short_links_path, "Short Links", [ ADMIN ] ],
      "new short link" => [ new_admin_short_link_path, "New Short Link", [ ADMIN, "Short Links" ] ],
      "nfl weeks" => [ admin_nfl_weeks_path, "NFL Weeks", [ ADMIN ] ],
      "drop signups" => [ admin_drop_signups_path, "Drop Signups", [ ADMIN ] ],
      "drop announcement" => [ admin_drop_signups_announcement_path, "Drop Announcement", [ ADMIN, "Drop Signups" ] ],
      "entry gifts" => [ admin_entry_gifts_path, "Gift a Free Entry", [ ADMIN ] ],
      "held paid entries" => [ admin_landed_entries_path, "Held Paid Entries", [ ADMIN ] ],
      "referrals" => [ admin_referrals_path, "Referrals", [ ADMIN ] ],
      "transactions" => [ admin_transactions_path, "Transaction Log", [ ADMIN ] ],
      "contest generator" => [ generator_contests_path, "Contest Generator", [ ADMIN ] ],
      "new contest" => [ new_contest_path, "New Contest", [ "Contests" ] ],
      "edit contest" => [ edit_contest_path(@contest), "Edit Contest", [ "Contests", @contest.name.truncate(40) ] ],
      "slate rankings" => [ slate_path(@slate), "Slate Rankings", [ ADMIN, "Slates" ] ],
      "slate manager" => [ manage_admin_slate_path(@slate), "Slate Manager", [ ADMIN, "Slates", @slate.name.truncate(40) ] ],
      "formula defaults" => [ admin_formula_slates_path, "Default Formula Variables", [ ADMIN, "Slates" ] ],
      # The app.
      "help center" => [ help_path, "Help Center", [] ],
      "how to play" => [ help_how_to_play_path, "How to Play", [ "Help Center" ] ],
      "glossary" => [ help_glossary_path, "Glossary", [ "Help Center" ] ],
      "phantom" => [ help_phantom_path, "Phantom Wallet", [ "Help Center" ] ],
      "about" => [ about_path, "About Turf Monster", [] ],
      "contact" => [ contact_path, "Contact", [] ],
      "terms" => [ terms_path, "Terms of Service", [] ],
      "privacy" => [ privacy_path, "Privacy Policy", [] ],
      "transparency" => [ transparency_path, "Transparency", [] ],
      "account" => [ account_path, "Account Settings", [] ],
      "wallet" => [ wallet_path, "Wallet", [] ],
      "contests" => [ contests_path, "Contests", [] ],
      "my contests" => [ my_contests_path, "My Contests", [ "Contests" ] ],
      "teams" => [ teams_path, "Teams", [] ],
      "players" => [ players_path, "Players", [] ],
      "games" => [ games_path, "Games", [] ],
      "toast test" => [ toast_test_path, "Toast Notifications", [] ],
      "seeds lab" => [ seeds_lab_path, "Seeds Loader Lab", [] ]
    }
  end

  # Gets the page with the engine's actions_html deprecation hook armed, and no RPC.
  def get_header(path)
    sites = []
    Solana::Vault.stub :new, FakeVault.new(seasons: [ { season_id: 1, name: "Season 1" } ]) do
      Studio::PageHeader.stub(:warning_enabled?, true) do
        Studio::PageHeader.stub(:deprecate_actions_html, ->(site: nil, **) { sites << site }) do
          get path
        end
      end
    end
    assert_response :success, path
    assert_empty sites, "#{path} passes actions_html to studio/page_header"
    css_select("#{ROW} .page-header-actions > *").each do |el|
      assert_includes KINDS, el["class"].to_s.split.first, "#{path}: a header control outside the engine's kinds"
    end
  end

  # main's h1s, less the navbar previews on /admin/navbar, each a copy of the real bar.
  def main_h1s = css_select("main h1").reject { |h1| h1.ancestors.any? { |node| node["class"].to_s.split.include?("navbar-preview") } }

  def assert_standard_header(name, title, ancestors)
    assert_equal 1, css_select(ROW).size, "#{name}: one engine page header"
    assert_equal [ title ], main_h1s.map { |h1| h1.text.strip }, "#{name}: main's one h1 is the header's title"
    assert_select "#{ROW} h1.page-header-title", { text: title, count: 1 }, name
    trail = css_select("#{ROW} nav.page-header-crumbs a.page-header-crumb").map { |a| a.text.strip }
    assert_equal ancestors, trail, "#{name}: the crumb trail"
    return if ancestors.empty?

    assert_select "#{ROW} .page-header-crumb-current[aria-current=page]", 1
    assert_select "#{ROW} a.page-header-parent", 1
  end

  test "[component] every converted page renders studio/page_header with its crumbs and main's one h1" do
    pages.each do |name, (path, title, ancestors)|
      get_header path
      assert_standard_header(name, title, ancestors)
    end
  end

  test "[component] the old back links are the trail's last crumb" do
    {
      admin_error_log_path(@error_log.slug) => admin_error_logs_path,
      admin_outbound_request_path(@outbound) => admin_outbound_requests_path,
      admin_experiment_path(@experiment.slug) => admin_experiments_path,
      edit_admin_landing_page_path(@landing_page) => admin_landing_pages_path,
      help_glossary_path => help_path,
      manage_admin_slate_path(@slate) => slate_path(@slate),
      admin_formula_slates_path => slates_path
    }.each do |path, back|
      get_header path
      assert_equal back, css_select("#{ROW} nav.page-header-crumbs a.page-header-crumb").last&.[]("href"), path
      assert_select "#{ROW} a.page-header-parent[href=?]", back
    end
  end

  test "[component] the old header buttons are the engine's kinds: the action and the Links menu" do
    get_header admin_drop_signups_path
    assert_select "#{ROW} a.page-header-action[href=?][data-test=drop-signups-announce]", admin_drop_signups_announcement_path
    assert_select "#{ROW} .page-header-menu-list a.page-header-menu-item", text: "Export CSV"

    get_header admin_experiment_path(@experiment.slug)
    assert_select "#{ROW} a.page-header-action[href=?]", edit_admin_experiment_path(@experiment.slug), text: "Edit"

    get_header generator_contests_path
    assert_select "#{ROW} a.page-header-action[href=?]", new_contest_path

    get_header slate_path(@slate)
    assert_select "#{ROW} .page-header-menu-list a.page-header-menu-item[href=?]", contests_path, text: "Contests"
  end

  test "[component] a POST button and a new-tab link stay on the page, under the header" do
    get_header admin_free_entries_path
    assert_select "#{ROW} form", 0
    assert_select "form[action=?] button", admin_mint_all_free_entries_path, text: /Mint All Owed/

    get_header edit_admin_landing_page_path(@landing_page)
    assert_select "#{ROW} a[target=_blank]", 0
    assert_select "a[target=_blank][href=?]", landing_page_path(@landing_page), text: "View page →"
  end

  test "[component] a meta the engine hides on a phone keeps a phone copy" do
    get_header games_path
    count = "#{Game.count} games"
    assert_select "#{ROW} .page-header-meta", text: count
    assert_select "[data-test=games-count-phone].sm\\:hidden", text: count
  end

  test "[unit] every key the views name is in the crumb map" do
    keys = Dir[Rails.root.join("app/views/**/*.erb")].flat_map do |file|
      File.read(file).scan(/studio_crumbs\((?:parent: )?:(\w+)/).flatten
    end.uniq
    assert_operator keys.size, :>=, 15
    keys.each { |key| assert Studio.crumbs.key?(key), "Studio.crumbs has no page :#{key}" }
  end
end
