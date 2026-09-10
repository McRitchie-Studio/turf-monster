require "test_helper"

# With seeded DK odds on a fifa slate, /slates/formula_report renders live
# samples again: the iteration tables, computed v1/v2/v3 scores, and the
# playground data all come from the odds-bearing matchups.
class SlatesFormulaReportSamplesTest < ActionDispatch::IntegrationTest
  setup do
    log_in_as(users(:alex)) # admin — the report is admin-gated

    @belgium = Team.create!(name: "Belgium Test", slug: "belgium-test", short_name: "BLT", emoji: "🔴")
    @opponent = Team.create!(name: "Opponent Test", slug: "opponent-test", short_name: "OPT", emoji: "⚪")
    slate = Slate.create!(name: "Group Stage — Samples", starts_at: 2.days.from_now)
    SlateMatchup.create!(
      slate: slate, team_slug: @belgium.slug, opponent_team_slug: @opponent.slug,
      status: "pending", expected_score: 1.5, team_total_over_odds: -175, team_total_under_odds: 110
    )
  end

  test "renders odds-bearing matchups with computed scores" do
    get formula_report_slates_path

    assert_response :success
    assert_includes response.body, "Belgium Test"
    # V3 anchored score for a 1.5 line at -175: the prose's Belgium 1.41.
    assert_includes response.body, "1.41"
    # Playground data carries the sample too.
    assert_match(/_playgroundMatchups = \[\{.*Belgium Test/, response.body)
  end

  test "line-only matchups on the same slate stay out of the sample" do
    lineless = Team.create!(name: "Lineless Test", slug: "lineless-test", short_name: "LNT", emoji: "⚫")
    slate = Slate.find_by!(name: "Group Stage — Samples")
    SlateMatchup.create!(
      slate: slate, team_slug: lineless.slug, opponent_team_slug: @belgium.slug,
      status: "pending", expected_score: 2.5
    )

    get formula_report_slates_path

    assert_response :success
    assert_includes response.body, "Belgium Test"
    refute_match(/_playgroundMatchups = \[[^\]]*Lineless Test/, response.body)
  end
end
