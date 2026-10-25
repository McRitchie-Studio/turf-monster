require "test_helper"

# [component] The navbar is studio-engine's (/tasks/turf-readopts-engine-navbar)
# and its content comes from the engine's slots. config/initializers/studio.rb
# declares Studio.navbar_links (Contests, Rules), Studio.navbar_items (the geo
# badge, the wallet signal) and Studio.navbar_avatar_badge (the ✨ free-entry
# badge), and the engine's layouts/_navbar and components/_user_nav draw them.
#
# EACH SLOT IS PROVEN LIVE BY EMPTYING IT. A host copy of either partial that
# hard-coded the geo badge would pass every presence check here; only a render
# that loses the badge when the setting goes empty shows the bar reads it.
class NavbarEngineSlotsTest < ActionDispatch::IntegrationTest
  HEADER = "header[data-navbar-root]".freeze
  DESKTOP_NAV = "#{HEADER} nav.md\\:flex".freeze
  PHONE_ROW = "#{HEADER} > div.md\\:hidden".freeze

  test "the initializer declares the three slots" do
    assert_equal %w[components/geo_badge shared/wallet_signal], Studio.navbar_items
    assert_equal "components/entry_token_badge", Studio.navbar_avatar_badge
    assert Studio.navbar_links.respond_to?(:call), "the links read route helpers off the view"
  end

  test "links and items render in both rows, signed out and signed in" do
    [ nil, users(:alex) ].each do |user|
      log_in_as(user) if user
      get contests_path
      assert_response :success

      [ DESKTOP_NAV, PHONE_ROW ].each do |row|
        assert_select "#{row} a[href='#{contests_path}']", { text: "Contests", count: 1 }, row
        assert_select "#{row} a[href='#{turf_monster_v1_path}']", { text: "Rules", count: 1 }, row
        assert_select "#{row} [data-geo-badge]", 1, row
        assert_select "#{row} [data-wallet-signal-variant=chip]", 1, row
      end
    end
  end

  test "the links keep the bar's old look: no primary tone on their own page" do
    get contests_path
    assert_select "#{HEADER} a[href='#{contests_path}'][aria-current]", 0
    assert_select "#{HEADER} a[href='#{contests_path}'].text-secondary", 2
  end

  test "the avatar badge renders in the engine's seat beside the account control, signed in only" do
    get contests_path
    assert_select "#{HEADER} [data-free-entry-badge]", 0

    log_in_as(users(:alex))
    get contests_path
    assert_select "#{HEADER} [data-nav-account] + [data-nav-avatar-badge] [data-free-entry-badge]", 1
    assert_select "#{HEADER} [data-nav-account] [data-free-entry-badge]", 0,
                  "never inside the account button: a button in a button reaches a screen reader as nothing"
  end

  test "Turf keeps no copy of the engine's navbar or user nav" do
    %w[app/views/layouts/_navbar.html.erb app/views/components/_user_nav.html.erb].each do |path|
      refute Rails.root.join(path).exist?, "#{path} would shadow the engine's in this non-isolated engine"
    end
  end

  test "emptying a slot empties the bar: the engine reads the settings" do
    items, badge, links = Studio.navbar_items, Studio.navbar_avatar_badge, Studio.navbar_links
    Studio.navbar_items = []
    Studio.navbar_avatar_badge = nil
    Studio.navbar_links = []

    log_in_as(users(:alex))
    get contests_path
    assert_response :success
    assert_select "#{HEADER} [data-geo-badge]", 0
    assert_select "#{HEADER} [data-wallet-signal-variant=chip]", 0
    assert_select "#{HEADER} [data-free-entry-badge]", 0
    assert_select "#{HEADER} a[href='#{turf_monster_v1_path}']", 0
  ensure
    Studio.navbar_items = items
    Studio.navbar_avatar_badge = badge
    Studio.navbar_links = links
  end
end
