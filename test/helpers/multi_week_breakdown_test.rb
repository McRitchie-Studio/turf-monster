require "test_helper"

# The per-week breakdown a multi-week pick shows on the leaderboard.
class MultiWeekBreakdownTest < ActionView::TestCase
  include ContestsHelper

  setup do
    @contest = contests(:one)
    @span = Slate.create!(name: "NFL 2026 Weeks 1-3", slug: "nfl-2026-weeks-1-3", week: 1)

    # Three games for team-a, all carrying the same FROZEN multiplier — which is
    # what ranking a span slate writes to every row of a team.
    @games = (1..3).map do |week|
      SlateMatchup.create!(
        slate: @span, team_slug: "team-a", opponent_team_slug: "team-f",
        game_slug: "team-a-wk#{week}-#{SecureRandom.hex(3)}",
        week: week, expected_score: 25.0, turf_score: 2.0, rank: 1, status: "pending"
      )
    end
    @contest.update!(slate: @span)

    entry = entries(:one)
    entry.selections.destroy_all
    @selection = Selection.create!(entry: entry, slate_matchup: @games.first)
  end

  def breakdown
    weekly_points_breakdown(@selection.reload,
                            weeks: [1, 2, 3],
                            by_team: @contest.matchups_by_team,
                            multiplier: 2.0)
  end

  test "shows each week's goals, the span total, and the one multiplier" do
    @games[0].update!(goals: 2)
    @games[1].update!(goals: 3)
    @games[2].update!(goals: 1)
    @selection.compute_points!

    assert_equal "W1 2 · W2 3 · W3 1 · 6 goals × 2.0 = 12.0 pts", breakdown
  end

  test "an unplayed week shows a dash, not a zero" do
    @games[0].update!(goals: 2)
    @selection.compute_points!

    # A dash distinguishes "hasn't happened yet" from "was shut out" — a zero
    # for weeks 2 and 3 would read as the team having been held scoreless.
    assert_includes breakdown, "W1 2 · W2 — · W3 —"
    assert_includes breakdown, "2 goals"
  end

  test "a shutout week shows 0, distinct from an unplayed one" do
    @games[0].update!(goals: 2)
    @games[1].update!(goals: 0)
    @selection.compute_points!

    assert_includes breakdown, "W1 2 · W2 0 · W3 —"
    assert_includes breakdown, "2 goals"
  end

  test "a bye week shows a dash rather than raising" do
    @games[2].destroy! # team-a is on bye in week 3
    @games[0].update!(goals: 2)
    @games[1].update!(goals: 3)
    @selection.compute_points!

    assert_includes breakdown, "W1 2 · W2 3 · W3 —"
    assert_includes breakdown, "5 goals"
  end
end
