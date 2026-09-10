require "test_helper"
require "rake"

# slates:recompute_turf_scores — repricing pass after a formula change:
# rewrites stored turf scores from each slate's sport curve while PRESERVING
# stored ranks (drag-curated orders must survive).
class SlatesRecomputeTurfScoresTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("slates:recompute_turf_scores")
    @task = Rake::Task["slates:recompute_turf_scores"]
    @task.reenable
  end

  test "reprices both sports from stored ranks without reordering" do
    nfl = Slate.create!(name: "NFL 2026 Week 9 Test")
    fifa = Slate.create!(name: "Quarter-finals Test")
    nfl_rows = %w[team-a team-b team-c team-d].each_with_index.map do |slug, index|
      SlateMatchup.create!(slate: nfl, team_slug: slug, status: "pending",
                           rank: index + 1, turf_score: 9.9)
    end
    fifa_rows = %w[team-e team-f].each_with_index.map do |slug, index|
      SlateMatchup.create!(slate: fifa, team_slug: slug, status: "pending",
                           rank: index + 1, turf_score: 9.9)
    end

    capture_io { @task.invoke }

    # NFL: linear from the pinned 1.0 base to the x2.0 top across n=4 teams.
    assert_equal [1.0, 1.3, 1.7, 2.0], nfl_rows.map { |m| m.reload.turf_score.to_f }
    assert_equal [1, 2, 3, 4], nfl_rows.map(&:rank)
    # Fifa: log curve — rank 1 pins to 1.0, rank 2 of 2 tops out at 3.0.
    assert_equal [1.0, 3.0], fifa_rows.map { |m| m.reload.turf_score.to_f }
  end
end
