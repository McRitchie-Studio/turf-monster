require "test_helper"

# This app's geo POLICY, now that the model behind it is the engine's
# (Studio::GeoSetting, studio-engine >= 0.57). What is asserted here is what this
# app decides — the published exclusion list and its enforcement — not the
# engine's mechanics, which are unit-tested in the gem.
class GeoSettingTest < ActiveSupport::TestCase
  test "the configured default list includes CA (2025 CA AG opinion) alongside the DFS-prohibited set" do
    %w[WA ID MT LA AZ HI NV CA].each do |code|
      assert_includes Studio.geo_default_banned_subdivisions, code
    end
  end

  test "the published list falls back to the configured defaults when no row is provisioned" do
    assert_not Studio::GeoSetting.current.persisted?, "precondition: no geo fixture"
    assert_equal Studio.geo_default_banned_subdivisions.sort,
                 Studio::GeoSetting.banned_subdivision_codes.sort
  end

  test "the published list reads the persisted row — published policy tracks enforcement" do
    Studio::GeoSetting.create!(app_name: Studio.app_name, enabled: true,
                               banned_subdivisions: %w[NY CA NY])

    assert_equal %w[CA NY], Studio::GeoSetting.banned_subdivision_codes.sort,
                 "deduped, and rendered as the bare codes the page prints"
  end

  # The bare codes this app has always stored are canonicalised to region tokens
  # on write ("CA" is California AND Canada). The published page still prints the
  # bare code, so the move is invisible to a reader and unambiguous to the gate.
  test "a bare state code is stored as a US region token" do
    setting = Studio::GeoSetting.create!(app_name: Studio.app_name, enabled: true,
                                         banned_subdivisions: %w[CA])

    assert_equal %w[US-CA], setting.reload.banned_subdivisions
  end

  test "blocked? enforces the persisted row" do
    Studio::GeoSetting.create!(app_name: Studio.app_name, enabled: true, banned_subdivisions: %w[CA])

    assert Studio::GeoSetting.blocked?(country: "US", subdivision: "CA")
    assert_not Studio::GeoSetting.blocked?(country: "US", subdivision: "CO")
    # The collision this app inherited protection from: a Canadian visitor whose
    # region normalises to "CA" is NOT in California.
    assert_not Studio::GeoSetting.blocked?(country: "CA", subdivision: "CA")
  end

  test "enforcing? is true only for a provisioned + enabled row" do
    assert_not Studio::GeoSetting.enforcing?, "no row → the gate is off"

    setting = Studio::GeoSetting.create!(app_name: Studio.app_name, enabled: false,
                                         banned_subdivisions: %w[CA])
    assert_not Studio::GeoSetting.enforcing?, "persisted but disabled → the gate is off"

    setting.update!(enabled: true)
    assert Studio::GeoSetting.enforcing?, "persisted + enabled → the gate is live (fail-closed applies)"
  end
end
