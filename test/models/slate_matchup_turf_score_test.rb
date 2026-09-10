require "test_helper"

# Sport-aware Turf Score with the base PINNED to 1.0: rank 1 always prices
# x1.0 in both sports; only the top of the curve differs — log decay for
# soccer, linear for the NFL (whose scoring is near-linear by rank).
class SlateMatchupTurfScoreTest < ActiveSupport::TestCase
  test "rank one is always x1 in both sports" do
    assert_equal 1.0, SlateMatchup.turf_score_for(1, 32, sport: "fifa")
    assert_equal 1.0, SlateMatchup.turf_score_for(1, 32, sport: "nfl")
  end

  test "soccer keeps the log curve" do
    assert_equal 3.0, SlateMatchup.turf_score_for(32, 32, sport: "fifa")
    # ln(4)/ln(16) = 0.5 -> 1.0 + 2.0 * 0.5
    assert_equal 2.0, SlateMatchup.turf_score_for(4, 16, sport: "fifa")
  end

  test "nfl runs linear between the pinned base and the x2 top" do
    assert_equal 2.0, SlateMatchup.turf_score_for(32, 32, sport: "nfl")
    # (3-1)/(5-1) = 0.5 -> exactly halfway up the curve
    assert_equal 1.5, SlateMatchup.turf_score_for(3, 5, sport: "nfl")
    # Linear spacing: consecutive ranks step evenly (log would front-load)
    step1 = SlateMatchup.turf_score_for(2, 33, sport: "nfl") - SlateMatchup.turf_score_for(1, 33, sport: "nfl")
    step2 = SlateMatchup.turf_score_for(33, 33, sport: "nfl") - SlateMatchup.turf_score_for(32, 33, sport: "nfl")
    assert_in_delta step1, step2, 0.11
  end

  test "defaults to the soccer curve and survives a one-team slate" do
    assert_equal SlateMatchup.turf_score_for(4, 16, sport: "fifa"), SlateMatchup.turf_score_for(4, 16)
    assert_equal 1.0, SlateMatchup.turf_score_for(1, 1, sport: "nfl")
  end
end
