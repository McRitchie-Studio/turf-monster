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

  # The cells that actually disagreed before the fix. Two sweeps, each over BOTH
  # curves, n 2-48, every rank, and all 21 slider positions (0.0-10.0 by 0.5),
  # comparing Ruby's `round(1)` against `toFixed(1)` emulated exactly (half-up
  # on the binary double, via Rational). Each count belongs to the total beside
  # it — a ratio quoted without its run's factor set cannot be re-derived:
  #
  #   game factors 1.0, 1.5        ->  249 of  98,700 cells (244 nfl, 5 fifa)
  #   game factors 1.0, 1.5, 1.25  ->  314 of 148,050 cells (309 nfl, 5 fifa)
  #
  # An earlier revision of this comment paired the 314 with the OTHER run's
  # 98,700, so neither half could be checked against the run that produced it.
  # That is why each line above carries its own total and its own factor set.
  #
  # n=32 is NOT clear, and the five cells there are not the NFL board: all five
  # are on the FIFA curve (factor 1.5, scales 3.5/4.5/5.5/6.5/9.5), and n=32 is
  # the only slate size where fifa diverges at all. NFL at n=32 is clean — the
  # NFL curve diverges only where (n-1) is a multiple of 5 (n = 6, 11, 16 … 46),
  # and 32 is not one of those. Slate SIZE is not sport: 32 teams is a World Cup
  # group stage as readily as an NFL season.
  #
  # Both coordinates below were measured, not derived; the earlier revision of
  # this test cited two that never diverged at all.
  test "a tie that JavaScript rounded down now reads Ruby's answer" do
    nfl = turf_score_scale_table(slate: slate_double, teams: 6, factors: [1.5])
    fifa = turf_score_scale_table(slate: slate_double(sport: "fifa"), teams: 32, factors: [1.5])

    # (1 + 6.5 * 1/5) * 1.5 = 2.9500000000000006 — Ruby 3.5, toFixed(1) 3.4
    assert_equal 3.5, nfl.fetch("6.5").fetch("1.5")[1]
    # (1 + 3.5 * ln(2)/ln(32)) * 1.5 = 2.55 — Ruby 2.6, toFixed(1) 2.5
    assert_equal 2.6, fifa.fetch("3.5").fetch("1.5")[1]
  end

  # The bug the review caught, and the reason it outranked the one above: a
  # rounding disagreement moves a price by 0.1, but a MISSING KEY returns null
  # for every row at once. `multScale` does not start on the slider — it starts
  # at the slate's resolved `formula_mult_scale`, and that admin field steps by
  # 0.1, so 2.3 is a value one admin can type and no slider position can equal.
  # Every price then reads null, and a drag-reorder plus "Save Multipliers"
  # persists each team's OLD price against its NEW rank.
  test "an off-grid resolved scale still has a row" do
    table = turf_score_scale_table(slate: slate_double, teams: 8, factors: [1.0], resolved_scale: 2.3)

    assert_includes table.keys, "2.3"
    assert_equal 22, table.size, "the 21 slider positions plus the off-grid scale"
    assert_equal SlateMatchup.turf_score_for(8, 8, sport: "nfl", game_factor: 1.0, scale: 2.3),
                 table.fetch("2.3").fetch("1.0").last
  end

  test "a resolved scale already on the grid adds no duplicate row" do
    table = turf_score_scale_table(slate: slate_double, teams: 8, factors: [1.0], resolved_scale: 2.5)

    assert_equal 21, table.size
    assert_equal SLIDER_SCALES.map { |scale| format("%.1f", scale) }, table.keys
  end

  # The same defect one layer down, and the reason `price_key` rounds before it
  # formats. A five-week span with a bye prices its bye teams at 5/4 = 1.25.
  # `format("%.1f", 1.25)` is half-to-even → "1.2"; JS `(1.25).toFixed(1)` is
  # half-up → "1.3". The line would key to a factor row that does not exist.
  test "a factor key matches what toFixed would ask for" do
    table = turf_score_scale_table(slate: slate_double, teams: 8, factors: [1.25])

    assert_equal ["1.3"], table.fetch("1.0").keys
  end

  # Both keys come from one rule, so neither can drift from the other.
  test "every span-and-bye factor keys the way JavaScript rounds it" do
    # toFixed(1): half-up on the exact binary double, which Rational gives us.
    js_to_fixed = ->(value) { format("%.1f", (Rational(value) * 10).round(half: :up) / 10.0) }

    (1..20).each do |span_games|
      (1..span_games).each do |games|
        factor = span_games.to_f / games
        assert_equal js_to_fixed.call(factor), price_key(factor),
                     "span #{span_games} / #{games} games"
      end
    end
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
