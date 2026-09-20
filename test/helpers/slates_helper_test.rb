require "test_helper"

# [unit] ONE implementation of the price.
#
# The admin board used to recompute the curve in JavaScript so the slider could
# preview a scale Ruby had no parameter for. Two implementations, two rounding
# rules: Ruby rounds a tie away from zero on the decimal, `toFixed` rounds the
# binary double. Since "Save Multipliers" posts what is ON SCREEN, the page
# could persist a price the curve never produced.
#
# The table below is now the only source the page reads, so these tests are
# about one property: every cell in it IS `SlateMatchup.turf_score_for`.
class SlatesHelperTest < ActionView::TestCase
  include SlatesHelper

  def slate_double(sport: "nfl")
    Struct.new(:sport).new(sport)
  end

  test "the table covers every slider position" do
    table = turf_score_scale_table(slate: slate_double, teams: 8, factors: [1.0])

    # min 0, max 10, step 0.5 — the range input's own 21 positions.
    assert_equal 21, table.size
    assert_equal "0.0", table.keys.first
    assert_equal "10.0", table.keys.last
    assert_equal %w[0.0 0.5 1.0 1.5], table.keys.first(4)
  end

  test "every cell is the shipped curve's own answer" do
    table = turf_score_scale_table(slate: slate_double, teams: 12, factors: [1.0, 1.5])

    table.each do |scale, lines|
      lines.each do |factor, prices|
        prices.each_with_index do |price, index|
          expected = SlateMatchup.turf_score_for(index + 1, 12, sport: "nfl",
                                                               game_factor: factor.to_f,
                                                               scale: scale.to_f)
          assert_equal expected, price, "scale #{scale} factor #{factor} rank #{index + 1}"
        end
      end
    end
  end

  # The cells that actually disagreed before the fix, measured by sweeping both
  # curves over n 2-48 at every slider position: 369 of 74,025. NONE at n=32,
  # so the NFL board was never exposed — these are World Cup-sized slates.
  test "a tie that JavaScript rounded down now reads Ruby's answer" do
    nfl = turf_score_scale_table(slate: slate_double, teams: 6, factors: [1.5])
    fifa = turf_score_scale_table(slate: slate_double(sport: "fifa"), teams: 9, factors: [1.0])

    # (1 + 3.5 * 1/5) * 1.5 = 2.55 — Ruby 2.6, toFixed(1) 2.5
    assert_equal 2.6, nfl.fetch("3.5").fetch("1.5")[1]
    # (1 + 2.5 * ln(3)/ln(9)) = 2.25 — Ruby 2.3, toFixed(1) 2.2
    assert_equal 2.3, fifa.fetch("2.5").fetch("1.0")[2]
  end

  test "the sport's own scale is what an unslid page shows" do
    nfl = turf_score_scale_table(slate: slate_double, teams: 32, factors: [1.0])
    fifa = turf_score_scale_table(slate: slate_double(sport: "fifa"), teams: 32, factors: [1.0])

    # Default scale: NFL tops at x2.0, soccer at x3.0 — the curve's own defaults,
    # reachable on the slider at 1.0 and 2.0 respectively.
    assert_equal SlateMatchup.turf_score_for(32, 32, sport: "nfl"), nfl.fetch("1.0").fetch("1.0").last
    assert_equal SlateMatchup.turf_score_for(32, 32, sport: "fifa"), fifa.fetch("2.0").fetch("1.0").last
  end

  test "passing no scale leaves every existing caller's answer unchanged" do
    (1..32).each do |rank|
      assert_equal SlateMatchup.turf_score_for(rank, 32, sport: "nfl", scale: 1.0),
                   SlateMatchup.turf_score_for(rank, 32, sport: "nfl")
      assert_equal SlateMatchup.turf_score_for(rank, 32, sport: "fifa", scale: 2.0),
                   SlateMatchup.turf_score_for(rank, 32, sport: "fifa")
    end
  end

  test "a duplicated line is asked for once" do
    table = turf_score_scale_table(slate: slate_double, teams: 4, factors: [1.0, 1.0, 1.5, 1.0])

    assert_equal %w[1.0 1.5], table.fetch("1.0").keys
  end

  test "an empty slate charts nothing rather than raising" do
    assert_empty turf_score_scale_table(slate: slate_double, teams: 0, factors: [1.0])
  end
end
