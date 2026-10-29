require "test_helper"

# [component] The signed-in navbar's long-name and labelling seams
# (/tasks/turf-navbar-polish). The layout and the labels are measured in a
# browser (e2e/navbar_polish.spec.js); what a render can prove is here:
#
#   · the name the server draws is the username, in the name control and as
#     the avatar's label, so the e2e's long name is the real render;
#   · both theme toggles render from the engine's morph partial, where
#     nav_labels.js finds them (.nav-toggle-icon > button), and Turf keeps no
#     copy of the toggle (labelling it here, not forking it, is the point);
#   · nav_labels is pinned and imported, or none of it reaches the page;
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

  test "both theme toggles render where nav_labels.js looks, and Turf keeps no copy of them" do
    log_in_as(users(:alex))
    get contests_path

    assert_select "#{HEADER} .nav-toggle-icon > button[title='Toggle theme']", 2
    %w[_theme_toggle _theme_toggle_morph].each do |partial|
      refute Rails.root.join("app/views/components/#{partial}.html.erb").exist?,
             "#{partial} would shadow the engine's; nav_labels.js labels the engine's instead"
    end
  end

  test "nav_labels is pinned and imported by the application entry point" do
    assert_includes Rails.application.importmap.packages.keys, "nav_labels"
    assert_match(/^import "nav_labels"$/, Rails.root.join("app/javascript/application.js").read)
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
