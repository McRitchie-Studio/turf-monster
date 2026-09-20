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

  # --- the y domain --------------------------------------------------------

  # The frame exists to hold the DOTS as much as the lines. A price is written
  # from the admin board with no bound, so a hand-edited multiplier can sit above
  # the top of its line or below x1.0; sized to the lines alone, the chart clipped
  # exactly those marks.
  test "a normally priced slate keeps the domain the lines alone would give" do
    lines = benchmark_lines(slate_double(games_per_team: 3, two_line: true), 32)
    priced = lines.flat_map(&:points).map { |point| row_double(point.turf_score) }

    assert_equal [1.0, 3.0], benchmark_y_domain(lines: lines, team_rows: priced),
                 "a dot ON its line must not move the frame"
  end

  test "a price above the top of its line widens the domain to hold it" do
    lines = benchmark_lines(slate_double(games_per_team: 3, two_line: true), 32)

    y_min, y_max = benchmark_y_domain(lines: lines, team_rows: [row_double(3.5)])

    assert_operator y_max, :>, 3.5, "3.5x belongs inside the frame, not on its edge"
    assert_equal 1.0, y_min, "the floor is untouched by a high outlier"
  end

  test "a price below the floor widens the domain downward" do
    lines = benchmark_lines(slate_double(games_per_team: 3, two_line: true), 32)

    y_min, y_max = benchmark_y_domain(lines: lines, team_rows: [row_double(0.6)])

    assert_operator y_min, :<, 0.6, "0.6x belongs inside the frame, not on its edge"
    # 0.6 - 0.1 is 0.49999999999999994 in binary floating point, and flooring
    # that to a tenth gives 0.4 -- a tenth of air is worked in tenths for this.
    assert_equal 0.5, y_min
    assert_equal 3.0, y_max, "the ceiling is untouched by a low outlier"
  end

  test "an unpriced slate keeps the floor at x1.0 rather than collapsing" do
    lines = benchmark_lines(slate_double(games_per_team: 3, two_line: true), 32)

    # No stored price leaves NO dots at all. A min taken over that is nil, and
    # reading it as a number drops the floor below zero and squashes the chart.
    assert_equal [1.0, 3.0], benchmark_y_domain(lines: lines, team_rows: [row_double(nil)])
  end

  test "an unchartable slate answers with the default frame, not an exception" do
    empty = benchmark_lines(slate_double(games_per_team: 3, two_line: false), 0)

    assert_equal [1.0, 2.0], benchmark_y_domain(lines: empty, team_rows: [])
  end

  private

  def slate_double(games_per_team:, two_line:)
    Struct.new(:games_per_team, :sport, :two_line_pricing?)
          .new(games_per_team, "nfl", two_line)
  end

  # Only the stored multiplier is read off a team row here, so that is all the
  # double carries -- and nil is a real value for it, on a slate nobody priced.
  def row_double(turf_score)
    Struct.new(:turf_score).new(turf_score)
  end
end
