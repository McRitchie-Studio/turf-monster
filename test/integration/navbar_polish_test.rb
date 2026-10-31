require "test_helper"

# [component] The signed-in navbar's long-name and labelling seams
# (/tasks/turf-navbar-polish). The layout and the labels are measured in a
# browser (e2e/navbar_polish.spec.js); what a render can prove is here:
#
#   · the name the server draws is the username, in the name control and as
#     the avatar's label, so the e2e's long name is the real render;
#   · both theme toggles render from the engine's morph partial, named by the
#     engine (type="button", aria-label="Dark theme", a bound aria-pressed,
#     studio-engine 0.119.1), and Turf keeps no copy of the toggle and no
#     script relabelling it (/tasks/turf-navbar-stopgap-cleanup retired
#     nav_labels.js);
#   · the name control carries the full name as its title, from the engine;
#   · POST /test/set_username validates as a user's own change does.
class NavbarPolishTest < ActionDispatch::IntegrationTest
  HEADER = "header[data-navbar-root]".freeze
  LONG_NAME = "Christopher_Montgomery_Wellin".freeze

  test "a long username renders in the name control and labels the avatar" do
    log_in_as(users(:alex))
    post "/test/set_username", params: { username: LONG_NAME }
    assert_response :success
    get contests_path
    assert_response :success

    assert_select "#{HEADER} [data-nav-name-trigger] [data-nav-name]", text: LONG_NAME, count: 1
    assert_select "#{HEADER} [data-nav-account][aria-label=?]", LONG_NAME, 1
  end

  test "both theme toggles render the engine's own name and pressed state, and Turf keeps no copy of them" do
    log_in_as(users(:alex))
    get contests_path

    toggles = css_select("#{HEADER} .nav-toggle-icon > button")
    assert_equal 2, toggles.size, "the desktop rail and the phone row each draw one toggle"
    toggles.each do |toggle|
      assert_equal "button", toggle["type"]
      assert_equal "Dark theme", toggle["aria-label"], "the engine's fixed name, not a Turf relabel"
      # aria-pressed is an Alpine binding on the theme store; the browser half
      # (it reads "true" in dark and "false" in light) is e2e/navbar_polish.spec.js.
      assert_equal "$store.theme.isDark ? 'true' : 'false'", toggle[":aria-pressed"]
    end
    %w[_theme_toggle _theme_toggle_morph].each do |partial|
      refute Rails.root.join("app/views/components/#{partial}.html.erb").exist?,
             "#{partial} would shadow the engine's, which names the toggle itself"
    end
  end

  test "the name control carries the full name as its title" do
    log_in_as(users(:alex))
    post "/test/set_username", params: { username: LONG_NAME }
    get contests_path

    assert_select "#{HEADER} [data-nav-name-trigger][title=?]", LONG_NAME, 1
  end

  test "no stopgap relabels the navbar: nav_labels is gone from the pins, the entry point and the tree" do
    refute_includes Rails.application.importmap.packages.keys, "nav_labels"
    refute_match(/nav_labels/, Rails.root.join("app/javascript/application.js").read)
    refute Rails.root.join("app/javascript/nav_labels.js").exist?
  end

  test "set_username sets a valid name for the signed-in user and refuses an invalid one" do
    post "/test/set_username", params: { username: LONG_NAME }
    assert_response :unauthorized

    user = users(:alex)
    log_in_as(user)
    post "/test/set_username", params: { username: LONG_NAME }
    assert_response :success
    assert_equal LONG_NAME, user.reload.username

    post "/test/set_username", params: { username: "has spaces in it" }
    assert_response :unprocessable_entity
    assert_equal LONG_NAME, user.reload.username

    post "/test/set_username", params: { username: "x" * 31 }
    assert_response :unprocessable_entity
  end
end
