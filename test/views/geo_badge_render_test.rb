require "test_helper"

# [component] The navbar geo badge, rendered WITHOUT a signed-in user.
#
# The badge used to hide behind logged_in?, which read as "not showing" — and
# hid the state-eligibility signal from exactly the visitors deciding whether
# to sign up. Detection is IP-based (detect_geo_state runs for every request),
# so the badge renders for everyone: flag + code when the state resolves, a
# red "??" when it cannot, red when blocked or overridden.
#
# The stub module stands in for the controller helper_methods (geo_state,
# geo_blocked?, geo_override_active?) the partial reads; the test case's ivars
# are copied into the view, so the module reads them there. Crucially there is
# NO logged_in? stub: a partial that still referenced it would raise, so every
# test below doubles as the signed-out regression guard.
class GeoBadgeRenderTest < ActionView::TestCase
  module GeoStubs
    def geo_state = @geo_state
    def geo_blocked? = @geo_blocked
    def geo_override_active? = @geo_override
  end
  helper GeoStubs

  def render_badge(state:, blocked: false, override: false)
    @geo_state = state
    @geo_blocked = blocked
    @geo_override = override
    render partial: "components/geo_badge"
  end

  test "a resolved state renders publicly with its flag" do
    html = render_badge(state: "CO")

    assert_match(/class="geo-badge/, html, "the badge must render with no signed-in user")
    assert_includes html, ">\n  CO", "the state code is the badge text"
    assert_includes html, 'src="/state-flags/co.svg"', "a resolved state carries its flag"
    assert_includes html, "text-secondary", "an allowed state wears the neutral style"
  end

  test "an unresolved state renders the fail-closed red ??" do
    html = render_badge(state: nil, blocked: true)

    assert_match(/class="geo-badge/, html)
    assert_includes html, "??", "an undetectable location must say so, not vanish"
    assert_includes html, "text-red-400", "fail-closed reads as blocked, in red"
    refute_includes html, "<img", "no state, no flag"
  end

  test "a blocked state renders red" do
    html = render_badge(state: "WA", blocked: true)

    assert_includes html, "text-red-400"
    assert_includes html, 'src="/state-flags/wa.svg"'
  end
end
