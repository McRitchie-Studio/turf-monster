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

  # THE PHANTOM-MOCK HANDOFF MUST FOLLOW A RENAME.
  #
  # This endpoint used to resolve the human operator by USERNAME, which has moved
  # twice (`alex` -> `mcritchie` -> `alex`). A stale value there does not fail as
  # a missing user — it finds the OTHER seeded admin and tries to hand it a wallet
  # the human already holds, so the whole Playwright run dies in globalSetup with
  # a 422 that reads as a wallet bug. This is the cheapest tier that reproduces it.
  test "the phantom mock wallet lands on the human operator, whatever their username" do
    silence_warnings { load Rails.root.join("db/seeds/users.rb") }
    capture_io { seed_core_users! }
    human = User.find_by!(email: TestController::HUMAN_ADMIN_EMAIL)
    canonical = human.web3_solana_address

    post "/test/use_phantom_mock_admin"

    assert_response :success
    assert_equal TestController::PHANTOM_MOCK_WALLET, human.reload.web3_solana_address
    assert_equal 1, User.where(web3_solana_address: TestController::PHANTOM_MOCK_WALLET).count,
      "two accounts cannot hold the mock wallet — the unique index is what 422s"

    post "/test/restore_canonical_admin"

    assert_response :success
    assert_equal canonical, human.reload.web3_solana_address
  end

  # The endpoint is only correct if it lands on the account the ROSTER calls the
  # human. Pinning the email alone would pass with the roster pointing anywhere.
  test "the human operator is a parked admin, not just any row" do
    identity = User.parked_identity_for(email: TestController::HUMAN_ADMIN_EMAIL)

    refute_nil identity, "the phantom-mock handoff targets an email no parked identity claims"
    assert_equal "admin", identity[:role]
  end
end
