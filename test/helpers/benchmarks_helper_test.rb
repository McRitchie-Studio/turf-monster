require "test_helper"

# [unit] The chart's numbers come from the SHIPPED curve, not from a second
# drawing of it. That is the whole property worth testing here: a picture that
# derives its own line can start lying the moment the curve is re-tuned, and it
# would keep looking plausible while it did.
class BenchmarksHelperTest < ActionView::TestCase
  include BenchmarksHelper

  test "every point is the curve's own answer for that rank" do
    points = turf_score_curve(teams: 32, sport: "nfl")

    assert_equal 32, points.size
    points.each do |point|
      assert_equal SlateMatchup.turf_score_for(point.rank, 32, sport: "nfl"), point.turf_score,
                   "rank #{point.rank} must be the shipped curve's value, not a redrawn one"
    end
  end

  test "the bye line is the same curve scaled, ends included" do
    bye = turf_score_curve(teams: 32, sport: "nfl", game_factor: 1.5)

    assert_equal 1.5, bye.first.turf_score
    assert_equal 3.0, bye.last.turf_score
    assert_equal 32, bye.size
  end

  test "it is a staircase, because the price is" do
    scores = turf_score_curve(teams: 32, sport: "nfl").map(&:turf_score)

    # Rounded to a tenth, 32 ranks cannot yield 32 distinct prices — and the
    # chart must show that rather than smooth it into a ramp.
    assert_operator scores.uniq.size, :<, scores.size
    assert_equal scores, scores.sort, "price never falls as rank worsens"
  end

  test "a slate with no bye offers one line; a bye slate offers two" do
    full = slate_double(games_per_team: 3, two_line: false)
    bye = slate_double(games_per_team: 3, two_line: true)

    assert_equal ["full"], benchmark_lines(full, 32).map(&:key)
    assert_equal %w[full bye], benchmark_lines(bye, 32).map(&:key)
  end

  test "the labels name the game counts a reader is comparing" do
    lines = benchmark_lines(slate_double(games_per_team: 3, two_line: true), 32)

    assert_equal "3 games", lines.first.label
    assert_equal "2 games · bye", lines.second.label
    assert_equal 1.5, lines.second.game_factor
  end

  test "an empty or single-team slate charts nothing rather than dividing by zero" do
    assert_empty turf_score_curve(teams: 0, sport: "nfl")
    assert_equal [1.0], turf_score_curve(teams: 1, sport: "nfl").map(&:turf_score)
  end

  private

  def slate_double(games_per_team:, two_line:)
    Struct.new(:games_per_team, :sport, :two_line_pricing?)
          .new(games_per_team, "nfl", two_line)
  end
end
