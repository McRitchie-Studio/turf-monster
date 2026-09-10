require "test_helper"

# Integration: runs the model across its real I/O boundary — the checked-in
# 2023-2025 historical scores dataset — and asserts the structural properties
# the model promises, not exact fitted values (the dataset may be refreshed).
class NflPointsDistributionDatasetTest < ActiveSupport::TestCase
  test "checked-in dataset yields a full-week ranked model with a strong fit" do
    result = Nfl::PointsDistribution.call

    assert_equal [2023, 2024, 2025], result.seasons
    assert_equal 32, result.team_count

    # Every season contributes full weeks; the early (1-4) and late (15-18)
    # stretches have no byes, so at least 8 per season qualify.
    grouped = result.full_weeks.group_by(&:first)
    assert_equal [2023, 2024, 2025], grouped.keys.sort
    grouped.each_value { |weeks| assert_operator weeks.length, :>=, 8 }
    assert_equal result.full_weeks.length * 16, result.games_analyzed

    # Ranked expectations: 32 rows, strictly descending, plausible NFL points.
    assert_equal 32, result.expected_points_by_rank.length
    assert_equal result.expected_points_by_rank.sort.reverse, result.expected_points_by_rank
    assert_operator result.mean_points, :>, 17
    assert_operator result.mean_points, :<, 28

    # Both curve families fit and explain the shape.
    assert_equal %i[log linear], result.fits.keys
    result.fits.each_value { |fit| assert_operator fit.r_squared, :>, 0.85 }
    assert_includes %i[log linear], result.best_fit.kind
    assert_operator result.expected_points_for(1), :>, result.expected_points_for(32)
  end
end
