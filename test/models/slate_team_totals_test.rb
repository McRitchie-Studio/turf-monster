require "test_helper"

# A Slate is a POOL OF GAMES, not one NFL week. A team appears once per game it
# plays here, and everything it is priced on — expected points, rank, multiplier
# — is the SUM across those games. A one-week slate is the degenerate case.
class SlateTeamTotalsTest < ActiveSupport::TestCase
  setup do
    @slate = Slate.create!(name: "NFL 2026 Weeks 1-3", slug: "nfl-2026-weeks-1-3")
  end

  def add_game!(team_slug, opponent_slug, expected, kickoff: nil)
    game = Game.create!(
      slug: "#{team_slug}-vs-#{opponent_slug}-#{SecureRandom.hex(3)}",
      home_team_slug: team_slug, away_team_slug: opponent_slug,
      kickoff_at: kickoff, status: "scheduled"
    )
    SlateMatchup.create!(slate: @slate, team_slug: team_slug, opponent_team_slug: opponent_slug,
                         game_slug: game.slug, expected_score: expected, status: "pending")
  end

  # --- the core idea ------------------------------------------------------

  test "a team may play several games in one slate" do
    add_game!("team-a", "team-b", 20.0)
    add_game!("team-a", "team-c", 25.0)
    add_game!("team-a", "team-d", 30.0)

    assert_equal 3, @slate.matchups_by_team["team-a"].size
  end

  test "expected points is the sum across the team's games in the slate" do
    add_game!("team-a", "team-b", 20.0)
    add_game!("team-a", "team-c", 25.0)
    add_game!("team-a", "team-d", 30.5)

    assert_in_delta 75.5, @slate.expected_points_by_team["team-a"], 0.001
  end

  test "rank and turf derive from the summed total, not any single game" do
    # team-a has the WEAKEST single game (5.0) but the strongest three-week
    # total, so ranking on a single row would price it exactly backwards.
    add_game!("team-a", "team-b", 5.0)
    add_game!("team-a", "team-c", 30.0)
    add_game!("team-a", "team-d", 30.0)
    add_game!("team-b", "team-a", 20.0)
    add_game!("team-b", "team-c", 20.0)
    add_game!("team-b", "team-d", 20.0)

    rankings = @slate.team_rankings

    assert_equal 1, rankings["team-a"][:rank], "65.0 total should rank ahead of 60.0"
    assert_equal 2, rankings["team-b"][:rank]
    # rank 1 of n is always exactly 1.0; rank n of an NFL slate tops at 2.0
    # (linear curve, x2 cap — see SlateMatchup.turf_score_for).
    assert_equal 1.0, rankings["team-a"][:turf_score]
    assert_equal 2.0, rankings["team-b"][:turf_score]
  end

  test "team_rows carries one row per team with its games and total" do
    add_game!("team-a", "team-b", 20.0)
    add_game!("team-a", "team-c", 25.0)
    add_game!("team-b", "team-a", 30.0)

    rows = @slate.team_rows

    assert_equal 2, rows.size
    team_a = rows.find { |row| row.team_slug == "team-a" }
    assert_equal 2, team_a.matchups.size
    assert_in_delta 45.0, team_a.expected_points, 0.001
    # team-b's single 30.0 beats team-a's 45.0? No — 45 > 30, so team-a ranks 1.
    assert_equal 1, team_a.rank
  end

  test "team_rows is ordered by rank" do
    add_game!("team-a", "team-b", 10.0)
    add_game!("team-b", "team-a", 30.0)
    add_game!("team-c", "team-d", 20.0)

    assert_equal %w[team-b team-c team-a], @slate.team_rows.map(&:team_slug)
  end

  test "multi_game_per_team? and games_per_team describe the span" do
    add_game!("team-a", "team-b", 20.0)
    assert_not @slate.multi_game_per_team?
    assert_equal 1, @slate.games_per_team

    add_game!("team-a", "team-c", 20.0)
    assert @slate.reload.multi_game_per_team?
    assert_equal 2, @slate.games_per_team
  end

  # --- single-week must be untouched --------------------------------------

  test "a one-week slate ranks exactly as it did before" do
    # One game per team: summing one game is that game, so this must reproduce
    # the old per-row ranking exactly.
    add_game!("team-a", "team-b", 28.0)
    add_game!("team-b", "team-a", 24.0)
    add_game!("team-c", "team-d", 26.0)
    add_game!("team-d", "team-c", 22.0)

    rankings = @slate.team_rankings

    assert_equal %w[team-a team-c team-b team-d],
                 rankings.sort_by { |_slug, r| r[:rank] }.map(&:first)
    assert_equal 1.0, rankings["team-a"][:turf_score]
    assert_equal 2.0, rankings["team-d"][:turf_score]
  end

  test "ties break on kickoff then team name, matching the old ordering" do
    early = Time.zone.parse("2026-09-10 13:00")
    late  = Time.zone.parse("2026-09-14 13:00")
    add_game!("team-b", "team-c", 25.0, kickoff: late)
    add_game!("team-a", "team-d", 25.0, kickoff: early)

    # Equal totals: the earlier kickoff wins, NOT alphabetical order — that is
    # the ordering the per-row ranking used, and changing it would silently
    # re-price tied teams on every existing slate.
    assert_equal 1, @slate.team_rankings["team-a"][:rank]
    assert_equal 2, @slate.team_rankings["team-b"][:rank]
  end

  # --- the index that used to forbid this ---------------------------------

  test "the same team in the same game is still rejected" do
    matchup = add_game!("team-a", "team-b", 20.0)

    duplicate = SlateMatchup.new(slate: @slate, team_slug: "team-a",
                                 opponent_team_slug: "team-b",
                                 game_slug: matchup.game_slug,
                                 expected_score: 20.0, status: "pending")

    assert_not duplicate.valid?, "a team may play many games here, but not the SAME game twice"
  end
end
