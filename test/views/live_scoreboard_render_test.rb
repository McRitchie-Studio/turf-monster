require "test_helper"

# [component] The /live scoreboard, as it actually renders.
class LiveScoreboardRenderTest < ActionDispatch::IntegrationTest
  setup do
    @home = teams(:team_a)
    @away = teams(:team_b)
    @away.update!(league: "nfl", sport: "football")
    # Brand colors are the tile's whole visual language, so pin real values.
    @home.update!(color_dark: "#97233F", color_light: "#FFB612", color_disposition: "dark")
    @game = Game.create!(
      home_team_slug: @home.slug, away_team_slug: @away.slug,
      season_year: 2026, season_type: 1, week: 4,
      status: "in_progress", status_detail: "Q3 8:42", period: 3, clock: "8:42",
      kickoff_at: 1.hour.ago
    )
    @game.goals.create!(team_slug: @home.slug, points: 6, scoring_type: "touchdown")
    @game.goals.create!(team_slug: @away.slug, points: 3, scoring_type: "field_goal")
  end

  # Public on purpose: a scoreboard that demands a sign-in to show a score is
  # not a scoreboard.
  test "renders without a signed-in user" do
    get live_path

    assert_response :success
    assert_select "[data-test=?]", "live-game-tile"
  end

  test "shows each team's summed score, not its number of scoring events" do
    get live_path

    assert_response :success
    assert_select "[data-game-slug=?]", @game.slug do
      assert_select "[data-role=score]", text: "6"
      assert_select "[data-role=score]", text: "3"
    end
  end

  # The tile's brand rail is read from the team's own palette through
  # Team#card_background, so a light-field team gets its colors the right way
  # round instead of a hardcoded dark assumption.
  test "paints each team's rail in that team's brand color" do
    get live_path

    assert_match(/background:\s*#97233F/i, response.body)
  end

  # The row carries BOTH brand colors, because they do different jobs: the field
  # backs the wash and the rail glow, the ink colors the score. Shipping only the
  # field is not a cosmetic slip — Pittsburgh's is #101820, so the score that
  # just changed renders near-black on a dark board and reads as not having
  # changed at all.
  test "each row exposes the team's field AND ink colors to the animations" do
    get live_path

    assert_select "[data-game-slug=?] [data-team-slug=?]", @game.slug, @home.slug do |rows|
      style = rows.first["style"]
      assert_match(/--nfl-team:\s*#97233F/i, style)
      assert_match(/--nfl-team-ink:\s*#FFB612/i, style)
    end
  end

  test "each row carries the wash and rail the scoring animation targets" do
    get live_path

    assert_select "[data-game-slug=?]", @game.slug do
      assert_select ".nfl-row-wash", count: 2
      assert_select ".nfl-rail", count: 2
    end
  end

  test "labels a live game with its clock and a final game as final" do
    get live_path
    assert_select "[data-game-slug=?]", @game.slug do
      assert_select "*", text: /Q3 8:42/
      assert_select "*", text: /Live/i
    end

    @game.update!(status: "completed", status_detail: "Final")
    get live_path
    assert_select "[data-game-slug=?]", @game.slug do
      assert_select "*", text: /Final/
    end
  end

  test "titles the board with its season slot" do
    get live_path

    assert_select "h1", text: /Preseason/
    assert_select "h1", text: /Week 4/
  end

  # The stream subscription is what makes this page live at all — without it
  # the board is a snapshot that silently goes stale.
  test "subscribes to the nfl_live stream" do
    get live_path

    assert_select "turbo-cable-stream-source"
    assert_select "#nfl_live_scoreboard"
    assert_select "#nfl_live_event_feed"
  end

  # The dev toolbar writes real Goal rows. It must never be drawn in production.
  test "renders the dev score toolbar outside production" do
    get live_path

    assert_select "[data-test=?]", "dev-score-tools"
    assert_select "[data-test=?]", "dev-score-touchdown"
    assert_select "[data-test=?]", "dev-score-clear"
  end

  test "the dev toolbar is gated on the environment, not on markup alone" do
    Rails.env.stub(:local?, false) do
      get live_path

      assert_response :success
      assert_select "[data-test=?]", "dev-score-tools", count: 0
    end
  end
end
