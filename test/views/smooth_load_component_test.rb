require "test_helper"

# Guards turf-monster's smooth-load adoption (task: turf-monster-smooth-load).
#
# The change this locks in: TM opts into the engine 0.24 smooth-load
# convention (Studio.smooth_load = true → same-origin view-transition +
# turbo-cache-control no-preview metas via layouts/studio/head), pins the
# navbar as the page's ONE shared view-transition element (vt-pinned-header,
# non-preview renders only), drops the nav spinner display floor to 300ms per
# the engine's smooth-load guidance (the floor only pads fast navigations —
# remaining = max(0, min_ms - elapsed) — so slow RPC ops are unaffected by it),
# and forces reducedMotion in Playwright so e2e never waits on a transition.
#
# Structural regression risks: the config flag flipping back off, a future
# engine bump dropping the smooth-load CSS layer, the spinner floor drifting
# back up to the 2500 default, the preview navbar copies gaining the pin (a duplicate
# view-transition-name silently disables ALL transitions on the page), or the
# Playwright reducedMotion line being dropped and e2e going flaky on swaps.
class SmoothLoadComponentTest < ActiveSupport::TestCase
  ENGINE_CSS  = Studio::Engine.root.join("app/assets/tailwind/studio_engine/engine.css")
  NAVBAR_ERB  = Rails.root.join("app/views/layouts/_navbar.html.erb")
  PW_CONFIG   = Rails.root.join("playwright.config.js")

  test "[component] Studio.smooth_load is enabled" do
    assert_equal true, Studio.smooth_load,
      "config/initializers/studio.rb must set config.smooth_load = true"
  end

  test "[component] nav spinner display floor is 300ms per smooth-load guidance" do
    assert_equal 300, Studio.nav_spinner_min_ms,
      "nav_spinner_min_ms is a minimum DISPLAY floor (remaining = max(0, min_ms - elapsed)) — " \
      "it only pads fast navigations and does nothing for slow RPC ops. Smooth-load apps keep " \
      "it low (300ms) so the spinner never lingers after every turbo:load"
  end

  test "[component] engine gem resolves to 0.24+ and ships the smooth-load CSS layer" do
    version = Gem.loaded_specs.fetch("studio-engine").version
    assert_operator version, :>=, Gem::Version.new("0.24.0"),
      "smooth_load needs studio-engine >= 0.24.0 (0.23 has no accessor — NoMethodError at boot)"

    css = ENGINE_CSS.read
    assert_includes css, "vt-pinned-header",
      "engine.css must ship the pinned-header view-transition-name rule"
    assert_includes css, "view-transition-old",
      "engine.css must ship the view-transition pseudo-element rules " \
      "(they reach TM's build via the studio_engine import guarded in component_css_provenance_test)"
  end

  test "[component] navbar pins vt-pinned-header on the real render only, never the preview" do
    erb = NAVBAR_ERB.read
    assert_includes erb, "vt-pinned-header", "navbar header must carry vt-pinned-header"
    # The class must live in the non-preview branch of the ternary — the admin
    # navbar-review page renders preview copies of this partial in the body,
    # and a duplicate view-transition-name silently disables ALL transitions.
    assert_match(/is_preview \? 'bg-page' : 'vt-pinned-header /, erb,
      "vt-pinned-header must be in the NON-preview class branch only")
    assert_equal 2, erb.scan("vt-pinned-header").size,
      "expected vt-pinned-header exactly twice in the partial (comment + class); " \
      "a third occurrence suggests the preview branch got pinned too"
  end

  test "[component] playwright forces reducedMotion so e2e gets instant swaps" do
    config = PW_CONFIG.read
    use_block = config[/use:\s*\{.*?\n  \}/m]
    assert use_block, "use: block not found in playwright.config.js"
    assert_includes use_block, %(reducedMotion: "reduce"),
      "playwright use: must force reducedMotion — under prefers-reduced-motion Turbo " \
      "never starts the view transition at all, so e2e gets instant swaps"
  end
end
