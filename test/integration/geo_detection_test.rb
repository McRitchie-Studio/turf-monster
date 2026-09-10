require "test_helper"

# Integration coverage across the geo-detection I/O boundary (the ipinfo HTTP
# lookup, mocked here at Geocoder.search). Proves that once a lookup succeeds,
# the real detect_geo_state -> Studio::Geo normalization -> Studio::GeoSetting
# blocklist pipeline fires end-to-end through GET /geo/check.
#
# ADOPTION SEAM (studio-engine >= 0.57): every piece below the request is the
# ENGINE's now — detection, the policy, the probe. What this file proves is that
# THIS app is wired to it: its route, its blocklist, its fail-closed rule.
#
# COMPLIANCE: the legal-state blocklist FAILS CLOSED. When the gate is enabled
# but the lookup yields no subdivision (a VPN/proxy to an unknown IP, an ipinfo
# outage, or the 3s timeout), geo_state goes blank and geo_country defaults to
# "US" — which could mask a banned state. Such an undetectable US location is
# BLOCKED, never waved through (mirrors Cdp::Catalog's US+nil-subdivision
# fail-closed on the payments path). The earlier http-301 lookup regression
# made this path the norm; the fix here is that an undetectable US location can
# no longer evade the block by breaking geolocation.
class GeoDetectionTest < ActionDispatch::IntegrationTest
  GeoResult = Struct.new(:country_code, :state_code, :region_code, :region, keyword_init: true)

  setup do
    @geo = Studio::GeoSetting.current
    @geo.update!(enabled: true, banned_subdivisions: %w[WA ID MT])
  end

  test "a resolved ipinfo region normalizes to its 2-letter state code" do
    # ipinfo-via-Geocoder returns the full region name with a blank state_code.
    result = GeoResult.new(country_code: "US", state_code: "", region_code: nil, region: "California")
    Geocoder.stub :search, [result] do
      get geo_check_path
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "CA", body["state"]
    assert_equal false, body["blocked"], "California is not in this fixture's banned list"
  end

  test "a resolved banned state is blocked once geo detection works" do
    result = GeoResult.new(country_code: "US", state_code: "WA", region_code: nil, region: "Washington")
    Geocoder.stub :search, [result] do
      get geo_check_path
    end
    body = JSON.parse(response.body)
    assert_equal "WA", body["state"]
    assert_equal true, body["blocked"], "the WA blocklist must enforce when geo resolves"
  end

  test "an undetectable US location fails CLOSED (geo_check reports blocked)" do
    # The http-301 regression made EVERY lookup return nothing — geo_state went
    # blank, geo_country defaulted to "US", and the blocklist used to silently
    # fall open. With the gate enabled, an undetectable US location must now
    # report blocked: true so a banned-state user can't evade by breaking geo.
    Geocoder.stub :search, [] do
      get geo_check_path
    end
    body = JSON.parse(response.body)
    assert_nil body["state"], "an undetectable lookup still has no resolved state"
    assert_equal true, body["blocked"],
      "US + undetectable subdivision must fail CLOSED, not open (compliance)"
  end

  # ── require_geo_allowed enforcement on a real gated action ──────────────────

  test "an undetectable US location is blocked on a geo-gated entry action (fail closed)" do
    # The actual exposure: a banned-state user forces geolocation to fail
    # (VPN to an unknown IP / ipinfo outage) so geo_state is blank and
    # geo_country defaults to US. The require_geo_allowed before_action must
    # block the money/entry path, not permit it. Stub wraps login too, so the
    # cached geo session is the undetectable one for the gated POST.
    Geocoder.stub :search, [] do
      log_in_as users(:alex)

      post toggle_selection_contest_path(contests(:one)),
        params: { matchup_id: slate_matchups(:m1).id }, as: :json
      assert_response :forbidden,
        "an undetectable US location must be blocked on a geo-gated action"

      post enter_contest_path(contests(:one))
      assert_redirected_to root_path,
        "the html entry path must bounce an undetectable US location to root"
    end
  end

  test "a resolved allowed state passes the geo gate on a gated action" do
    # Positive control: a resolved, non-banned US state (CO) is NOT over-blocked
    # by the fail-closed path — the gated action proceeds normally.
    SeasonConfig.set_current!(1)
    allowed = GeoResult.new(country_code: "US", state_code: "CO", region_code: nil, region: "Colorado")
    Geocoder.stub :search, [allowed] do
      log_in_as users(:alex)

      post toggle_selection_contest_path(contests(:one)),
        params: { matchup_id: slate_matchups(:m1).id }, as: :json
    end
    assert_response :success,
      "a resolved allowed state must clear require_geo_allowed (no over-blocking)"
  end

  # ── stale-blank self-heal (the funding lock-out fix) ────────────────────────

  test "a transient blank lookup self-heals within minutes instead of sticking for a day" do
    # Regression: a user in an ALLOWED state (CO) first hits the site during an
    # ipinfo hiccup, so the lookup returns nothing and the gate fails closed.
    # Minutes later ipinfo recovers. The before_action must re-detect rather than
    # serve the day-long stale blank — otherwise "Buy USDC" stays disabled for an
    # allowed-state user (the bug Mr. McRitchie hit in Colorado on production).
    SeasonConfig.set_current!(1)
    colorado = GeoResult.new(country_code: "US", state_code: "CO", region_code: nil, region: "Colorado")

    # 1) First contact during an ipinfo outage -> blank state -> fail closed.
    Geocoder.stub :search, [] do
      log_in_as users(:alex)

      post toggle_selection_contest_path(contests(:one)),
        params: { matchup_id: slate_matchups(:m1).id }, as: :json
      assert_response :forbidden,
        "an undetectable US location must fail closed on first contact"
    end

    # 2) Only minutes pass — far less than the 24h the buggy code trusted — and
    #    ipinfo now resolves Colorado. The before_action must re-detect, so the
    #    allowed-state user clears the gate. Under the bug this stayed :forbidden.
    travel(Studio.geo_retry_ttl + 1.minute) do
      Geocoder.stub :search, [colorado] do
        post toggle_selection_contest_path(contests(:one)),
          params: { matchup_id: slate_matchups(:m1).id }, as: :json
      end
    end
    assert_response :success,
      "after the short retry window a recovered lookup must clear the gate " \
      "(no 24h stale-blank lock-out)"
  end

  # ── the public navbar badge ─────────────────────────────────────────────────

  test "the navbar geo badge renders for an anonymous visitor" do
    # No log_in_as: the badge is public. Detection is IP-based, so a signed-out
    # visitor sees where the browser appears to be — the signal a potential
    # sign-up needs BEFORE creating an account.
    result = GeoResult.new(country_code: "US", state_code: "", region_code: nil, region: "Colorado")
    Geocoder.stub :search, [result] do
      get contests_path
    end
    assert_response :success
    assert_select "span.geo-badge", minimum: 1, text: /CO/
    # The art ships in the gem now, so the src is an asset path (digested in a
    # built environment). Match the file, not the fingerprint.
    assert_select %(span.geo-badge img[src*="state-flags/co"]), minimum: 1
  end

  test "an anonymous visitor with an undetectable location sees the red ??" do
    Geocoder.stub :search, [] do
      get contests_path
    end
    assert_response :success
    assert_select "span.geo-badge", minimum: 1, text: /\?\?/
  end
end
