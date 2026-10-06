require "test_helper"

class ContestBundleTest < ActiveSupport::TestCase
  # Uses the "world_cup" bundle against the slate it names, seeded in setup.
  # (On-chain creation auto-skips in the test env.)
  setup { seed_bundle_slate!("world_cup") }

  test "generate! creates the contest and its landing page" do
    assert_difference ["Contest.count", "LandingPage.count"], 1 do
      ContestBundle.generate!("world_cup", creator: users(:alex))
    end
    lp = LandingPage.find_by(slug: "world-cup")
    assert lp.active?
    assert_equal "circles", lp.background_style
    assert_equal "World Cup $1000 Turf Total Contest", lp.contest.name
  end

  test "generate! is idempotent" do
    ContestBundle.generate!("world_cup", creator: users(:alex))
    assert_no_difference ["Contest.count", "LandingPage.count"] do
      ContestBundle.generate!("world_cup", creator: users(:alex))
    end
  end

  test "generate! raises on an unknown bundle key" do
    assert_raises(ArgumentError) { ContestBundle.generate!("nope") }
  end
end
