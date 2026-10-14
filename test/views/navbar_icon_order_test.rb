require "test_helper"

# The navbar's desktop icon rail: the theme toggle leads the gear, a size down
# at 14px, as on every engine navbar (studio-engine's components/_user_nav,
# task universal-navbar-account-primitive). This app forks that partial for its
# two-row nav, so it carries the order and size itself.
class NavbarIconOrderTest < ActionDispatch::IntegrationTest
  test "the theme toggle leads the gear and sits a size down" do
    log_in_as users(:sam)
    get contests_path
    assert_response :success

    # The ATTRIBUTE forms: the layout's gear-sidebar delegation script names the
    # gear's hook as a CSS selector earlier in the document.
    toggle_at = response.body.index('data-nav-theme-toggle="desktop"')
    gear_at = response.body.index('data-gear-sidebar-trigger="true"')

    assert toggle_at, "the desktop theme toggle should render"
    assert gear_at, "the gear should render for a signed-in user"
    assert toggle_at < gear_at, "the theme toggle must come before the gear"
    assert_select "[data-nav-theme-toggle='desktop'].scale-\\[0\\.875\\]", 1
  end
end
