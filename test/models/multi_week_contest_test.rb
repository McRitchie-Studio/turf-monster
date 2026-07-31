require "test_helper"

# A multi-week Turf Totals contest ("NFL Weeks 1-3") is played on ONE span slate
# holding several games per team. The player picks six TEAMS once, before week
# one's kickoff, and each pick scores that team's TOTAL goals across the span
# times ONE multiplier — the FROZEN turf_score stored on its matchup rows.
class MultiWeekContestTest < ActiveSupport::TestCase
  setup do
    @contest = contests(:one)
    @span = Slate.create!(name: "NFL 2026 Weeks 1-3", slug: "nfl-2026-weeks-1-3", week: 1)
  end

  # Three games for a team, all carrying the SAME frozen multiplier (that is what
  # ranking a span slate writes).
  def add_games!(team_slug, expectations, turf_score:, goals: [])
    expectations.each_with_index.map do |expected, index|
      SlateMatchup.create!(
        slate: @span, team_slug: team_slug, opponent_team_slug: "team-f",
        game_slug: "#{team_slug}-wk#{index + 1}-#{SecureRandom.hex(3)}",
        week: index + 1, expected_score: expected,
        turf_score: turf_score, rank: 1, goals: goals[index], status: "pending"
      )
    end
  end

  def span_contest!
    @contest.update!(slate: @span)
    @contest
  end

  def pick!(team_slug)
    entry = entries(:one)
    entry.selections.destroy_all
    Selection.create!(entry: entry, slate_matchup: @span.matchups_by_team[team_slug].first)
  end

  # --- span shape ---------------------------------------------------------

  test "a slate with several games per team makes the contest multi-week" do
    add_games!("team-a", [25.0, 25.0, 25.0], turf_score: 2.0)
    span_contest!

    assert @contest.multi_week?
    assert_equal 3, @contest.weeks_count
    assert_equal "Weeks 1-3", @contest.week_span_label
  end

  test "a single-game-per-team slate is NOT multi-week" do
    assert_not contests(:one).multi_week?
  end

  test "the pickable rows are one per team, not one per game" do
    add_games!("team-a", [25.0, 25.0, 25.0], turf_score: 2.0)
    add_games!("team-b", [20.0, 20.0, 20.0], turf_score: 3.0)
    span_contest!

    assert_equal 6, @contest.matchups.count, "six game rows in the pool"
    assert_equal 2, @contest.pickable_matchups.size, "but a pick is a TEAM"
    assert_equal %w[team-a team-b], @contest.pickable_matchups.map(&:team_slug).sort
  end

  # --- scoring ------------------------------------------------------------

  test "a pick scores total span goals times the ONE frozen multiplier" do
    add_games!("team-a", [25.0, 25.0, 25.0], turf_score: 2.0, goals: [2, 3, 1])
    span_contest!
    selection = pick!("team-a")

    selection.compute_points!

    assert_equal 12.0, selection.reload.points.to_f, "(2+3+1) goals x 2.0"
  end

  test "the multiplier is READ FROM STORAGE, not recomputed at scoring time" do
    # The defect this guards: the multiplier used to be recomputed live from
    # expected_score, and a projections refresh after lock re-ranked the
    # span — measured drift 1.0x at pick time to 3.0x at settlement. Settlement
    # is on-chain, so a player must be paid the price they were shown.
    add_games!("team-a", [25.0, 25.0, 25.0], turf_score: 1.0, goals: [2, 2, 2])
    span_contest!
    selection = pick!("team-a")
    selection.compute_points!
    assert_equal 6.0, selection.reload.points.to_f

    # Projections move hard AFTER the pick is locked. The frozen turf_score does
    # not, so the score must not move either.
    @span.slate_matchups.update_all(expected_score: 0.1)
    selection.compute_points!

    assert_equal 6.0, selection.reload.points.to_f,
                 "a projections refresh must not re-price a locked pick"
  end

  test "only completed games contribute, so the board accrues live" do
    add_games!("team-a", [25.0, 25.0, 25.0], turf_score: 2.0, goals: [2, nil, nil])
    span_contest!
    selection = pick!("team-a")

    selection.compute_points!

    assert_equal 4.0, selection.reload.points.to_f
  end

  test "points are left untouched when no game has a result yet" do
    add_games!("team-a", [25.0, 25.0, 25.0], turf_score: 2.0)
    span_contest!
    selection = pick!("team-a")
    selection.update!(points: 7.5)

    selection.compute_points!

    assert_equal 7.5, selection.reload.points.to_f
  end

  test "a bye contributes no goals and keeps the team's own multiplier" do
    # Operator ruling (2026-07-18): a bye is not a special case. It lowers the
    # team's projected total, which lowers its rank and RAISES its multiplier —
    # exactly the mechanism that equalises expected value across picks. So a bye
    # team simply plays fewer games at its own price.
    add_games!("team-a", [25.0, 25.0], turf_score: 2.5, goals: [2, 3])
    span_contest!
    selection = pick!("team-a")

    assert_nothing_raised { selection.compute_points! }
    assert_equal 12.5, selection.reload.points.to_f, "(2+3) goals x 2.5"
  end

  test "entry score sums its picks across the span" do
    add_games!("team-a", [25.0, 25.0, 25.0], turf_score: 2.0, goals: [2, 3, 1])
    add_games!("team-b", [20.0, 20.0, 20.0], turf_score: 3.0, goals: [1, 1, 1])
    span_contest!

    entry = entries(:one)
    entry.selections.destroy_all
    Selection.create!(entry: entry, slate_matchup: @span.matchups_by_team["team-a"].first)
    Selection.create!(entry: entry, slate_matchup: @span.matchups_by_team["team-b"].first)

    entry.reload.score!

    assert_in_delta 21.0, entry.reload.score, 0.001, "(6 x 2.0) + (3 x 3.0)"
  end

  test "weekly_breakdown labels each game by its own week" do
    add_games!("team-a", [25.0, 25.0, 25.0], turf_score: 2.0, goals: [2, 3, 1])
    span_contest!
    selection = pick!("team-a")

    assert_equal [1, 2, 3], selection.weekly_breakdown.map(&:first)
  end

  # --- the scoring trigger ------------------------------------------------

  test "a later-week game re-scores the contest through the plain slate_id" do
    add_games!("team-a", [25.0, 25.0, 25.0], turf_score: 2.0)
    span_contest!
    @contest.update!(status: "open")
    selection = pick!("team-a")

    week2 = @span.matchups_by_team["team-a"][1]
    game = Game.create!(slug: "wk2-#{SecureRandom.hex(3)}", home_team_slug: "team-a",
                        away_team_slug: "team-c", kickoff_at: 1.day.ago, status: "completed")
    week2.update!(game_slug: game.slug)

    game.update!(home_score: 3, away_score: 0)
    game.update_slate_matchups!

    # A span slate IS the contest's slate_id, so week 2 is reachable without a
    # join — the benefit of converging onto one slate.
    assert_equal 6.0, selection.reload.points.to_f
  end

  # --- single-week regression --------------------------------------------

  test "single-week scoring is unchanged" do
    selection = pick_single_week!
    slate_matchups(:m1).update!(goals: 4) # turf_score 1.0

    selection.compute_points!

    assert_equal 4.0, selection.reload.points.to_f
  end

  test "single-week points are left untouched with no result" do
    selection = pick_single_week!
    selection.update!(points: 3.3)
    slate_matchups(:m1).update!(goals: nil)

    selection.compute_points!

    assert_equal 3.3, selection.reload.points.to_f
  end

  def pick_single_week!
    entry = entries(:one)
    entry.selections.destroy_all
    Selection.create!(entry: entry, slate_matchup: slate_matchups(:m1))
  end
end
