require "test_helper"
require "tempfile"

class Nfl::PointsDistributionTest < ActiveSupport::TestCase
  # A 4-team league keeps the arithmetic checkable by hand. Weeks 1-2 are
  # full (every team plays); week 3 is a "bye" week (only one game) and must
  # be skipped.
  FULL_AND_PARTIAL_WEEKS = {
    "seasons" => [2023],
    "games" => [
      { "season" => 2023, "week" => 1, "away" => "AAA", "away_score" => 30, "home" => "BBB", "home_score" => 20 },
      { "season" => 2023, "week" => 1, "away" => "CCC", "away_score" => 10, "home" => "DDD", "home_score" => 40 },
      { "season" => 2023, "week" => 2, "away" => "AAA", "away_score" => 20, "home" => "CCC", "home_score" => 10 },
      { "season" => 2023, "week" => 2, "away" => "BBB", "away_score" => 50, "home" => "DDD", "home_score" => 0 },
      { "season" => 2023, "week" => 3, "away" => "AAA", "away_score" => 99, "home" => "BBB", "home_score" => 99 }
    ]
  }.freeze

  test "skips partial weeks and averages weekly scores by rank" do
    result = call_with(FULL_AND_PARTIAL_WEEKS)

    assert_equal [[2023, 1], [2023, 2]], result.full_weeks
    assert_equal 1, result.partial_weeks_skipped
    assert_equal 4, result.games_analyzed

    # Week 1 ranked: 40, 30, 20, 10 · week 2 ranked: 50, 20, 10, 0
    assert_equal [45.0, 25.0, 15.0, 5.0], result.expected_points_by_rank
    assert_equal 22.5, result.mean_points
  end

  test "excludes a sixteen-game week where a team appears twice" do
    dataset = {
      "seasons" => [2023],
      "games" => [
        { "season" => 2023, "week" => 1, "away" => "AAA", "away_score" => 30, "home" => "BBB", "home_score" => 20 },
        { "season" => 2023, "week" => 1, "away" => "CCC", "away_score" => 10, "home" => "AAA", "home_score" => 40 }
      ]
    }

    error = assert_raises(ArgumentError) { call_with(dataset) }
    assert_match(/No full weeks/, error.message)
  end

  test "best fit picks the log family for log-shaped scores" do
    # Rank means on the log curve 5 + 40 * ln(4/rank)/ln(4): 45, 25, 13.3, 5.
    dataset = {
      "seasons" => [2023],
      "games" => [
        { "season" => 2023, "week" => 1, "away" => "AAA", "away_score" => 45, "home" => "BBB", "home_score" => 25 },
        { "season" => 2023, "week" => 1, "away" => "CCC", "away_score" => 13.3, "home" => "DDD", "home_score" => 5 }
      ]
    }
    result = call_with(dataset)
    log = result.fits.fetch(:log)

    assert_equal :log, result.best_fit.kind
    assert_in_delta 5.0, log.base, 0.1
    assert_in_delta 40.0, log.scale, 0.1
    assert_in_delta 1.0, log.r_squared, 0.001
  end

  test "recovers exact linear curve with r squared one" do
    # Rank means 40, 30, 20, 10 — exactly base 10, scale 30 on the linear basis.
    dataset = {
      "seasons" => [2023],
      "games" => [
        { "season" => 2023, "week" => 1, "away" => "AAA", "away_score" => 40, "home" => "BBB", "home_score" => 30 },
        { "season" => 2023, "week" => 1, "away" => "CCC", "away_score" => 20, "home" => "DDD", "home_score" => 10 }
      ]
    }
    result = call_with(dataset)
    linear = result.fits.fetch(:linear)

    assert_equal :linear, result.best_fit.kind
    assert_in_delta 10.0, linear.base, 0.01
    assert_in_delta 30.0, linear.scale, 0.01
    assert_in_delta 1.0, linear.r_squared, 0.0001
    assert_in_delta 0.0, linear.rmse, 0.01
    assert_in_delta 40.0, result.expected_points_for(1), 0.01
    assert_in_delta 10.0, result.expected_points_for(4), 0.01
  end

  test "raises for a missing dataset file" do
    error = assert_raises(ArgumentError) do
      Nfl::PointsDistribution.call(path: "/nonexistent/scores.json")
    end
    assert_match(/Missing historical scores dataset/, error.message)
  end

  private

  def call_with(dataset, team_count: 4)
    file = Tempfile.new(["historical_scores", ".json"])
    file.write(JSON.generate(dataset))
    file.close
    Nfl::PointsDistribution.call(path: file.path, team_count: team_count)
  end
end
