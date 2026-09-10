require "test_helper"

# Regression: /slates/formula_report must render for EVERY slate data state.
# The report's sample tables read odds fields (over_odds, prob, v1..v3) that
# left SlateMatchup in the schema audit (1fd6c50), so any matchup carrying a
# expected_score produced a partial sample and 500'd the page — which is
# exactly what happened on prod when NFL 2026 Week 1 became the next slate.
class SlatesFormulaReportCrashTest < ActionDispatch::IntegrationTest
  setup do
    log_in_as(users(:alex)) # admin — the report is admin-gated
  end

  test "renders when the next slate is an NFL slate with expected points" do
    slate_with_lines!(name: "NFL 2026 Week 1")

    get formula_report_slates_path

    assert_response :success
    assert_select "h1", text: "DK Score Formula — Iterations"
  end

  test "renders when a soccer slate carries lines without odds" do
    slate_with_lines!(name: "Knockout Stage — Final")

    get formula_report_slates_path

    assert_response :success
    assert_select "h1", text: "DK Score Formula — Iterations"
  end

  private

  def slate_with_lines!(name:)
    slate = Slate.create!(name: name, starts_at: 2.days.from_now)
    game = Game.create!(
      slug: "team-a-vs-team-b-#{SecureRandom.hex(3)}",
      home_team_slug: "team-a", away_team_slug: "team-b", status: "scheduled"
    )
    SlateMatchup.create!(slate: slate, team_slug: "team-a", opponent_team_slug: "team-b",
                         game_slug: game.slug, expected_score: 24.5, status: "pending")
    slate
  end
end
