require "test_helper"

# The navbar's desktop icon rail: the theme toggle leads the gear, a size down
# at 14px, as on every engine navbar (studio-engine's components/_user_nav,
# task universal-navbar-account-primitive). This app renders that partial since
# /tasks/turf-readopts-engine-navbar, the gear riding Studio.navbar_menu_trigger,
# and engine.css sizes the toggle (THE ACCOUNT ROW).
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
    assert_select "[data-nav-tools] [data-nav-theme-toggle='desktop']", 1
    assert_select "[data-nav-tools] [data-nav-menu-trigger] [data-gear-sidebar-trigger]", 1,
                  "the gear is the menu trigger, in the admin dropdown's seat"
    engine_css = File.read(Studio::Engine.root.join("app/assets/tailwind/studio_engine/engine.css"))
    assert_includes engine_css, %(.nav-shell [data-nav-tools] [data-nav-theme-toggle="desktop"] { transform: scale(0.875); }),
                    "the engine draws the toggle a size down, at 14px"
  end
end
