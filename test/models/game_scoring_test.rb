require "test_helper"

# [unit] How a game's score is computed from its scoring events.
class GameScoringTest < ActiveSupport::TestCase
  # NOT a fixture game. studio-engine's Sluggable runs `before_save :set_slug`,
  # so EVERY Game#save! rewrites the slug from #name_slug — and a fixture whose
  # slug does not already equal its name_slug gets renamed by the first score
  # recomputation, orphaning every goal written before it. Building the game
  # from its own name_slug keeps the row stable across saves.
  setup do
    @home = teams(:team_a)
    @away = teams(:team_b)
    @game = Game.create!(
      home_team_slug: @home.slug, away_team_slug: @away.slug,
      season_year: 2026, season_type: 1, week: 4, status: "in_progress"
    )
  end

  # The change at the centre of NFL support: SUM the points, do not COUNT the
  # rows. A count cannot express a touchdown.
  test "the score sums points rather than counting rows" do
    @game.goals.create!(team_slug: @home.slug, points: 6, scoring_type: "touchdown")
    @game.goals.create!(team_slug: @home.slug, points: 1, scoring_type: "pat")
    @game.goals.create!(team_slug: @away.slug, points: 3, scoring_type: "field_goal")

    @game.reload
    assert_equal 7, @game.home_score
    assert_equal 3, @game.away_score
  end

  # The whole migration strategy rests on this. `points` defaults to 1, so every
  # World Cup goal written before the column existed still scores exactly one —
  # summing is a no-op for soccer and the only way NFL works.
  test "a goal written without a point value still counts for one" do
    goal = @game.goals.create!(team_slug: @home.slug)

    assert_equal 1, goal.points
    assert_equal 1, @game.reload.home_score
  end

  test "removing a scoring event takes its points back off the board" do
    touchdown = @game.goals.create!(team_slug: @home.slug, points: 6, scoring_type: "touchdown")
    @game.goals.create!(team_slug: @home.slug, points: 3, scoring_type: "field_goal")
    assert_equal 9, @game.reload.home_score

    touchdown.destroy!
    assert_equal 3, @game.reload.home_score
  end

  test "each scoring type is worth what the rules say" do
    assert_equal 6, Goal.points_for("touchdown")
    assert_equal 3, Goal.points_for("field_goal")
    assert_equal 2, Goal.points_for("two_point")
    assert_equal 2, Goal.points_for("safety")
    assert_equal 1, Goal.points_for("pat")
    assert_equal 1, Goal.points_for("goal")
  end

  # An unrecognised type must never silently score zero — a scoring event worth
  # nothing is worse than one worth a conservative single point.
  test "an unrecognised scoring type falls back to one point" do
    assert_equal 1, Goal.points_for("hail_mary")
  end

  test "rejects a scoring type outside the known set" do
    goal = @game.goals.build(team_slug: @home.slug, scoring_type: "nonsense")

    refute goal.valid?
    assert_includes goal.errors[:scoring_type], "is not included in the list"
  end
end
