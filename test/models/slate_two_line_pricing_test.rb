require "test_helper"

# Two lines on a span with a bye in it (Slate "Two lines"). Every team ranks on
# expected points PER GAME; a full-span team prices on the usual curve, and a
# team with its bye inside the span prices on that curve x span_games/games —
# x1.5 to x3.0 on a three-week NFL span. The factor is exactly what keeps a bye
# EV-neutral: two games at 1.5m score what three games at m do.
class SlateTwoLinePricingTest < ActiveSupport::TestCase
  setup do
    @slate = Slate.create!(name: "NFL 2026 Weeks 4-6", slug: "nfl-2026-weeks-4-6")
  end

  def team!(slug)
    Team.find_or_create_by!(slug: slug) { |team| team.name = slug.titleize }
  end

  def add_games!(team_slug, *expected)
    team!(team_slug)
    expected.each_with_index do |score, index|
      opponent = team!("opp-#{team_slug}-#{index}").slug
      game = Game.create!(slug: "#{team_slug}-vs-#{opponent}-#{SecureRandom.hex(3)}",
                          home_team_slug: team_slug, away_team_slug: opponent, status: "scheduled")
      SlateMatchup.create!(slate: @slate, team_slug: team_slug, opponent_team_slug: opponent,
                           game_slug: game.slug, expected_score: score, week: 4 + index, status: "pending")
    end
  end

  # --- the factor ---------------------------------------------------------

  test "a bye inside a three-game span scales the curve by 1.5" do
    assert_equal 1.5, Slate.game_factor(3, 2)
  end

  test "a full-span team, a one-week slate and a gameless team all scale by 1.0" do
    assert_equal 1.0, Slate.game_factor(3, 3)
    assert_equal 1.0, Slate.game_factor(1, 1)
    assert_equal 1.0, Slate.game_factor(3, 0), "never divides by zero"
  end

  test "the factor generalises past one bye" do
    assert_equal 3.0, Slate.game_factor(3, 1)
  end

  # --- the curve ----------------------------------------------------------

  test "the two-game line runs 1.5x to 3.0x on a 32-team NFL board" do
    assert_equal 1.5, SlateMatchup.turf_score_for(1, 32, sport: "nfl", game_factor: 1.5)
    assert_equal 3.0, SlateMatchup.turf_score_for(32, 32, sport: "nfl", game_factor: 1.5)
  end

  test "the three-game line is untouched by the new argument" do
    (1..32).each do |rank|
      assert_equal SlateMatchup.turf_score_for(rank, 32, sport: "nfl"),
                   SlateMatchup.turf_score_for(rank, 32, sport: "nfl", game_factor: 1.0)
    end
  end

  test "every rank's bye price is 1.5x its regular price, to the rounding" do
    (1..32).each do |rank|
      exact = (1.0 + (rank - 1) / 31.0) * 1.5
      assert_equal exact.round(1), SlateMatchup.turf_score_for(rank, 32, sport: "nfl", game_factor: 1.5),
                   "rank #{rank} must round ONCE, after scaling"
    end
  end

  # --- ranking ------------------------------------------------------------

  test "a strong bye team ranks on points per game, not its short total" do
    add_games!("bye-team", 27.0, 27.0)          # 54.0 total, 27.0 per game
    add_games!("full-team", 20.0, 20.0, 20.0)   # 60.0 total, 20.0 per game

    rankings = @slate.team_rankings

    assert_equal 1, rankings["bye-team"][:rank], "27/game beats 20/game, whatever the totals say"
    assert_equal 2, rankings["full-team"][:rank]
  end

  test "each team prices on its own line and reports which" do
    add_games!("bye-team", 27.0, 27.0)
    add_games!("full-team", 20.0, 20.0, 20.0)

    rankings = @slate.team_rankings

    assert_equal({ games: 2, game_factor: 1.5 }, rankings["bye-team"].slice(:games, :game_factor))
    assert_equal({ games: 3, game_factor: 1.0 }, rankings["full-team"].slice(:games, :game_factor))
    # Rank 1 of 2 on the bye line is 1.5x; rank 2 of 2 on the full line is 2.0x.
    assert_equal 1.5, rankings["bye-team"][:turf_score]
    assert_equal 2.0, rankings["full-team"][:turf_score]
  end

  test "at any rank, two games on the bye line are worth three on the full line" do
    per_game = 24.0
    (1..32).each do |rank|
      full = 3 * per_game * SlateMatchup.turf_score_for(rank, 32, sport: "nfl")
      bye = 2 * per_game * SlateMatchup.turf_score_for(rank, 32, sport: "nfl", game_factor: 1.5)
      # One rounding step (0.05 of a multiplier) on two games is the only gap.
      assert_in_delta full, bye, 2 * per_game * 0.05 + 3 * per_game * 0.05, "rank #{rank}"
    end
  end

  test "a span with no bye ranks and prices exactly as the summed total did" do
    totals = { "a" => [30.0, 20.0, 25.0], "b" => [22.0, 22.0, 22.0], "c" => [10.0, 35.0, 30.0],
               "d" => [18.0, 19.0, 17.0] }
    totals.each { |team, scores| add_games!(team, *scores) }

    by_sum = totals.sort_by { |_team, scores| -scores.sum }.map(&:first)
    rankings = @slate.team_rankings

    assert_equal by_sum, rankings.sort_by { |_team, r| r[:rank] }.map(&:first)
    by_sum.each_with_index do |team, index|
      assert_equal SlateMatchup.turf_score_for(index + 1, 4, sport: "nfl"), rankings[team][:turf_score]
    end
    assert_not @slate.two_line_pricing?
  end

  test "two_line_pricing? is true only when some team plays short" do
    add_games!("full-team", 20.0, 20.0, 20.0)
    assert_not @slate.two_line_pricing?

    add_games!("bye-team", 27.0, 27.0)
    assert @slate.reload.two_line_pricing?
  end

  test "team_rows carries the per-game figure and the line" do
    add_games!("bye-team", 27.0, 26.0)
    add_games!("full-team", 20.0, 20.0, 20.0)

    row = @slate.team_rows.find { |r| r.team_slug == "bye-team" }

    assert_in_delta 53.0, row.expected_points, 0.001
    assert_in_delta 26.5, row.expected_points_per_game, 0.001
    assert_equal 1.5, row.game_factor
  end
end
