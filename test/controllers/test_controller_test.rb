require "test_helper"

# /test/* endpoints are dev/test-only (routes gated `unless Rails.env.production?`)
# and exist so Playwright can reset cross-spec pollution via POST /test/reseed.
class TestControllerTest < ActionDispatch::IntegrationTest
  test "reseed resets the geo row to the seeded default (geo-blocking off)" do
    # Simulate a prior spec that left geo-blocking ENABLED with the banned
    # list cleared — the cross-spec DB pollution that flaked geo.spec.js in CI
    # (the `enabled` flag is a DB column, not session-scoped, so it survives
    # across spec files and retries).
    Studio::GeoSetting.current.tap { |g| g.assign_attributes(enabled: true, banned_subdivisions: []) }.save!
    assert Studio::GeoSetting.current.enabled?, "precondition: geo-blocking left on by a prior spec"

    post "/test/reseed"
    assert_response :success
    assert_includes JSON.parse(response.body)["cleared"], "geo_setting"

    geo = Studio::GeoSetting.current
    assert_not geo.enabled?, "reseed must turn geo-blocking back off"
    assert_equal Studio.geo_default_banned_subdivisions.sort, geo.subdivision_codes.sort,
      "reseed must restore the default banned states"
  end
end
