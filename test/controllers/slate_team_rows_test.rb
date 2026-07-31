require "test_helper"

# /slates/:slug ranks TEAMS, not matchup rows. A three-week slate must render 32
# rows, not 96, with each team's DK total summed across its games.
class SlateTeamRowsTest < ActionDispatch::IntegrationTest
  setup do
    @slate = Slate.create!(name: "NFL 2026 Weeks 1-3", slug: "nfl-2026-weeks-1-3")
    log_in_as(users(:alex)) # admin — the ranking UI is admin-gated
  end

  def add_game!(team_slug, opponent_slug, expected)
    game = Game.create!(
      slug: "#{team_slug}-vs-#{opponent_slug}-#{SecureRandom.hex(3)}",
      home_team_slug: team_slug, away_team_slug: opponent_slug, status: "scheduled"
    )
    SlateMatchup.create!(slate: @slate, team_slug: team_slug, opponent_team_slug: opponent_slug,
                         game_slug: game.slug, expected_score: expected, status: "pending")
  end

  test "a multi-week slate renders one row per team, not one per game" do
    add_game!("team-a", "team-b", 20.0)
    add_game!("team-a", "team-c", 25.0)
    add_game!("team-a", "team-d", 30.0)
    add_game!("team-b", "team-a", 10.0)

    get slate_path(@slate)

    assert_response :success
    # 4 matchup rows, 2 teams -> 2 sortable rows.
    assert_select "div.sortable-item", 2
  end

  test "the row shows every opponent and the summed DK total" do
    add_game!("team-a", "team-b", 20.0)
    add_game!("team-a", "team-c", 25.5)

    get slate_path(@slate)

    assert_response :success
    assert_includes response.body, "DK 45.5"
    # Opponents joined, so a player can see who the team faces across the span.
    assert_match(/vs\s+\S+\s*\/\s*\S+/, response.body)
  end

  test "a single-week slate still renders one row per team" do
    add_game!("team-a", "team-b", 28.0)
    add_game!("team-b", "team-a", 24.0)

    get slate_path(@slate)

    assert_response :success
    assert_select "div.sortable-item", 2
    assert_includes response.body, "DK 28.0"
  end

  test "dragging a team applies its new rank to every game it plays" do
    add_game!("team-a", "team-b", 30.0)
    add_game!("team-a", "team-c", 30.0)
    a_first = SlateMatchup.find_by(slate: @slate, team_slug: "team-a")
    add_game!("team-b", "team-a", 10.0)
    b_first = SlateMatchup.find_by(slate: @slate, team_slug: "team-b")

    # Drop team-b above team-a. The posted handle is ONE of team-b's matchups.
    patch update_rankings_slate_path(@slate), params: { matchup_ids: [b_first.id, a_first.id] }

    # Both of team-a's rows must carry rank 2 — pricing a multi-week team by
    # whichever row happened to be the drag handle is the bug this guards.
    ranks = SlateMatchup.where(slate: @slate, team_slug: "team-a").pluck(:rank)
    assert_equal [2, 2], ranks
    assert_equal [1], SlateMatchup.where(slate: @slate, team_slug: "team-b").pluck(:rank)
  end
end
