require "test_helper"

# V3 anchored DK Score, restored from 405f902. The first two vectors are the
# formula report's own prose examples (Belgium 1.41; Germany's 4.5-line tier).
class SlateMatchupDkScoreTest < ActiveSupport::TestCase
  test "anchors the line and spreads by implied probability" do
    # -175 favorite on a 1.5 line: prob 175/275 = .63636 -> 1.0 + .40909 = 1.41
    assert_in_delta 1.41, SlateMatchup.dk_score_for(1.5, -175), 0.001
    # -150 on a 4.5 line: prob .6 -> 4.0 + 0.3 = 4.3
    assert_in_delta 4.3, SlateMatchup.dk_score_for(4.5, -150), 0.001
  end

  test "positive odds convert through the underdog branch" do
    # +160: prob 100/260 = .38462 -> 1.0 + (-.11538 * 3) = 0.65
    assert_in_delta 0.65, SlateMatchup.dk_score_for(1.5, 160), 0.001
  end

  test "floors at zero for weak lines with long odds" do
    # 0.5 line, +200: 0.0 + (.33333 - .5) * 3 = -0.5 -> floored
    assert_equal 0.0, SlateMatchup.dk_score_for(0.5, 200)
  end

  test "returns nil when either input is missing" do
    assert_nil SlateMatchup.dk_score_for(nil, -150)
    assert_nil SlateMatchup.dk_score_for(1.5, nil)
  end
end
