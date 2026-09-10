require "test_helper"

# Both formula report pages watch document.documentElement class changes with a
# MutationObserver to rebuild their Chart.js charts on theme toggle. Inline
# scripts re-execute on every Turbo visit, so each page must hold the observer
# in a plain guarded var and disconnect it on turbo:before-cache (see
# docs/FORMULAS.md, "Theme-Observer Teardown Pattern").
class SlatesReportThemeObserverTest < ActionDispatch::IntegrationTest
  setup do
    log_in_as(users(:alex)) # admin — both reports are admin-gated
  end

  test "soccer formula report registers a guarded, torn-down theme observer" do
    get formula_report_slates_path

    assert_response :success
    assert_theme_observer_teardown "_themeObserver"
  end

  test "NFL report registers a guarded, torn-down theme observer" do
    get nfl_report_slates_path

    assert_response :success
    assert_theme_observer_teardown "_nflThemeObserver"
  end

  private

  # The page script must (1) declare the observer var without an initializer,
  # (2) guard creation so script re-runs never stack a second observer, and
  # (3) disconnect on turbo:before-cache with a self-removing once listener.
  def assert_theme_observer_teardown(var_name)
    body = response.body

    assert_includes body, "var #{var_name};"
    assert_includes body, "if (!#{var_name}) {"
    assert_includes body, "#{var_name} = new MutationObserver(function() {"
    assert_includes body,
      "#{var_name}.observe(document.documentElement, { attributes: true, attributeFilter: ['class'] });"
    assert_includes body, "document.addEventListener('turbo:before-cache', function() {"
    assert_includes body, "if (#{var_name}) { #{var_name}.disconnect(); }"
    assert_includes body, "#{var_name} = null;"
    assert_includes body, "}, { once: true });"

    # Exactly one live observer per visit: creation appears once, and no bare
    # un-assigned `new MutationObserver` registration remains on the page.
    assert_equal 1, body.scan("new MutationObserver(").length
    refute_match(/^\s*new MutationObserver\(/, body)
  end
end
