require "test_helper"

# The formula reports live on two link-tabs: /slates/formula_report (soccer DK
# iterations, untouched) and /slates/nfl_report (the NFL points-distribution
# model: rank chart, both fitted formulas, 32-row rank table).
class SlatesFormulaReportNflTest < ActionDispatch::IntegrationTest
  setup do
    log_in_as(users(:alex)) # admin — both reports are admin-gated
  end

  test "soccer report keeps its content and links to the NFL tab" do
    get formula_report_slates_path

    assert_response :success
    assert_select "h1", text: "DK Score Formula — Iterations"
    assert_select "a[href=?]", nfl_report_slates_path
    assert_select "a[href=?]", formula_report_slates_path
    assert_select "canvas#chart-v1", 1
    assert_select "canvas#chart-nfl-dist", 0
    refute_includes response.body, "_nflDist"
  end

  test "NFL report renders the model from the checked-in dataset" do
    get nfl_report_slates_path

    assert_response :success
    assert_select "h1", text: "NFL Points Distribution"
    assert_select "a[href=?]", formula_report_slates_path
    assert_select "canvas#chart-nfl-dist", 1
    assert_includes response.body, "_nflDist"
    assert_includes response.body, "Log — World Cup family"

    result = Nfl::PointsDistribution.call
    assert_select "table" do
      assert_select "td", text: format("%.2f", result.expected_points_by_rank.first)
    end
    assert_equal 32, result.team_count

    # The best-fit badge is data-driven, and the prose names the World Cup's
    # own constants only as the family's shape reference — the plotted log
    # coefficients live in the fit card, never in the sentence.
    assert_includes response.body, "Best fit"
    assert_includes response.body, result.best_fit.formula(result.team_count)
    assert_includes response.body, "only as the shape reference"
    assert_includes response.body, "#{result.partial_weeks_skipped} bye weeks were skipped"
  end

  test "NFL report shows an empty state for missing, corrupt, or malformed datasets" do
    failure_modes = [
      ArgumentError.new("Missing historical scores dataset"),
      JSON::ParserError.new("unexpected token"),
      KeyError.new("key not found: \"games\"")
    ]

    failure_modes.each do |error|
      Nfl::PointsDistribution.stub(:call, ->(*) { raise error }) do
        get nfl_report_slates_path
      end

      assert_response :success
      assert_select "canvas#chart-nfl-dist", 0
      assert_includes response.body, "Historical dataset not available"
      refute_includes response.body, "_nflDist"
    end
  end
end
