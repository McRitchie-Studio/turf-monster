require "test_helper"

# [unit] The worked examples on /turf-monster-v1.
#
# The page's whole claim is that its numbers are the real ones. That claim is
# only worth something if the numbers are DERIVED — so this pins the two
# derivations the page relies on, and pins them to the shipped sources rather
# than to a second copy of the arithmetic.
class TurfMonsterRulesTest < ActiveSupport::TestCase
  # --- the multiplier comes from the board's own curve --------------------------

  test "every example prices off SlateMatchup's NFL curve" do
    examples = TurfMonsterRules::LINEUP
    assert_equal 6, examples.size, "the example entry is six teams"

    examples.each do |example|
      expected = SlateMatchup.turf_score_for(example.rank, 32, sport: "nfl")
      assert_equal expected, example.turf_score,
                   "#{example.team_slug} at rank #{example.rank} must price at the curve's #{expected}"
    end
  end

  # The NFL curve is LINEAR to x2.0; the World Cup curve is logarithmic to x3.0.
  # A page built on the wrong one would still render and still read fine, so
  # assert the sport, not just the shape of the output.
  test "the lineup spans the NFL curve, not the soccer one" do
    scores = TurfMonsterRules::LINEUP.map(&:turf_score)

    assert_equal 1.0, scores.min, "rank 2 of 32 still rounds to the x1.0 floor"
    assert_equal 2.0, scores.max, "rank 32 is the NFL ceiling"
    assert scores.none? { |s| s > 2.0 }, "x2.0 is the NFL ceiling; x3.0 is the World Cup's"
  end

  # Both ends and the middle of the curve section 03 draws.
  test "the curve rows are the two ends and the middle" do
    ranks = TurfMonsterRules::CURVE.map { |row| row[:rank] }
    assert_equal [ 1, 16, 32 ], ranks

    assert_equal 1.0, TurfMonsterRules.turf_score_for_rank(1)
    assert_equal 1.5, TurfMonsterRules.turf_score_for_rank(16)
    assert_equal 2.0, TurfMonsterRules.turf_score_for_rank(32)
  end

  # --- the scoring example adds up ---------------------------------------------

  # An NFL selection scores its SUMMED points across the span times ONE frozen
  # multiplier (Selection#compute_points!). Assert that shape, per row.
  test "each row is its summed weekly points times its multiplier" do
    TurfMonsterRules::LINEUP.each do |example|
      assert_equal 3, example.weekly_points.size, "#{example.team_slug} plays three games in a Weeks 1-3 span"
      assert_equal example.weekly_points.sum, example.points_scored
      assert_equal (example.weekly_points.sum * example.turf_score).round(1), example.entry_points
    end
  end

  test "the total is the sum of the rows" do
    expected = TurfMonsterRules::LINEUP.sum(&:entry_points).round(1)

    assert_equal expected, TurfMonsterRules.lineup_total
    assert_operator TurfMonsterRules.lineup_total, :>, 0
  end

  # THE POINT THE PAGE IS MAKING, asserted rather than trusted: a longshot that
  # scores FEWER points can finish AHEAD of a favorite. If the example data ever
  # stops demonstrating that, the section's prose is lying.
  test "a longshot outscores a favorite on fewer points" do
    favorite = TurfMonsterRules::LINEUP.min_by(&:turf_score)
    longshot = TurfMonsterRules::LINEUP.find { |e| e.turf_score >= 1.8 && e.points_scored < favorite.points_scored }

    assert longshot, "the example needs a longshot scoring fewer raw points than the favorite"
    assert_operator longshot.entry_points, :>, favorite.entry_points,
                    "the whole strategy section rests on this comparison"
  end

  # --- the query the page issues ------------------------------------------------

  # The controller loads these in ONE query. Every slug the page draws must be in
  # it — including the OPPONENTS, whose chips wear their own brand color, which
  # is the half a "load the six picks" version would miss.
  test "team_slugs covers the picks, their opponents, and the curve rows" do
    slugs = TurfMonsterRules.team_slugs

    assert_equal slugs.uniq, slugs, "the controller uses this as one where(slug:) — no duplicates"

    TurfMonsterRules::LINEUP.each do |example|
      assert_includes slugs, example.team_slug
      example.opponent_slugs.each { |opponent| assert_includes slugs, opponent }
    end
    TurfMonsterRules::CURVE.each { |row| assert_includes slugs, row[:team_slug] }
    assert_includes slugs, TurfMonsterRules::FEATURE.team_slug
  end
end
