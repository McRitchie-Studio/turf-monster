require "test_helper"

# [component] The navbar geo badge, rendered WITHOUT a signed-in user.
#
# The partial is the ENGINE's now (studio-engine >= 0.57, components/_geo_badge)
# and this app renders it through the host view path. These cases stay here
# because they are what THIS app's navbar must do — the engine carries its own
# copy of them against the same partial.
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
    def geo_country = @geo_country
  end
  helper GeoStubs

  def render_badge(state:, blocked: false, override: false, country: "US")
    @geo_state = state
    @geo_blocked = blocked
    @geo_override = override
    @geo_country = country
    render partial: "components/geo_badge"
  end

  test "a resolved state renders publicly with its flag" do
    html = render_badge(state: "CO")

    assert_match(/class="geo-badge/, html, "the badge must render with no signed-in user")
    assert_includes html, ">\n  CO", "the state code is the badge text"
    assert_match(%r{src="[^"]*state-flags/co[^"]*\.svg"}, html, "a resolved state carries its flag")
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
    assert_match(%r{src="[^"]*state-flags/wa[^"]*\.svg"}, html)
  end

  # --- non-US visitors (operator-reported: bare text, no flag) ---------------
  #
  # The shipped flag set is US states ONLY, so every foreign visitor fell
  # through the lookup to no flag at all. Operator screenshots: a Canadian IP
  # rendered as bare "Alberta", a UK IP as "England".

  test "a non-US visitor gets their country flag beside the region" do
    html = render_badge(state: "Alberta", country: "CA")

    assert_includes html, "\u{1F1E8}\u{1F1E6}", "a Canadian visitor sees the Canadian flag"
    assert_includes html, "Alberta", "the region text is kept"
    refute_includes html, "state-flags/", "a foreign visitor must never be given a US state flag"
  end

  # THE TRAP, and the reason this is a guard rather than a cosmetic fix.
  # The flag lookup matches a bare two-letter code, so a FOREIGN region whose
  # code collides with a US state — "CA" in Italy, Canada, or Egypt — would be
  # shown the CALIFORNIA flag. Wrong, and wrong in the way that looks right.
  test "a foreign region code colliding with a US state never shows the state flag" do
    html = render_badge(state: "CA", country: "IT")

    refute_match(%r{state-flags/ca[^"]*\.svg}, html,
                 "an Italian region 'CA' must NOT render the California flag")
    refute_includes html, "state-flags/",
                    "no US state asset may be reached while the visitor is foreign"
    assert_includes html, "\u{1F1EE}\u{1F1F9}", "it shows the Italian flag instead"
  end

  test "a US visitor still gets the state flag, not a country flag" do
    html = render_badge(state: "CO", country: "US")

    assert_match(%r{src="[^"]*state-flags/co[^"]*\.svg"}, html, "US visitors keep the state flag")
    refute_includes html, "\u{1F1FA}\u{1F1F8}", "and are not given a redundant US flag"
  end

  test "an unknown country code degrades to text rather than garbage" do
    html = render_badge(state: "Somewhere", country: "XX!")

    assert_includes html, "Somewhere", "the region text still renders"
    refute_includes html, "state-flags/", "still no US state flag for a foreign visitor"
  end

  # THE HOLE A MUTATION FOUND HERE, and the reason the engine's lookup guards on
  # `country == home` rather than `unless foreign?`. The two cases above pass
  # even WITHOUT that guard, because a rendered country flag
  # takes the `if` and the `elsif` is never reached — so they cannot see the
  # guard at all. The guard only bites where the country flag is ABSENT and the
  # region code still collides: an unparseable country plus a state-shaped
  # region. Without it, that visitor is served the California flag.
  test "a foreign visitor with an unrenderable country code still never gets a state flag" do
    html = render_badge(state: "CA", country: "XX!")

    refute_match(%r{state-flags/ca[^"]*\.svg}, html,
                 "no country flag is possible here, and that must mean NO flag — not California's")
    refute_includes html, "state-flags/",
                    "the state-flag lookup must not be reachable for a foreign visitor at all"
    assert_includes html, "CA", "the region text still renders"
  end
end
