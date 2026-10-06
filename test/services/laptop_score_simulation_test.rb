require "test_helper"

# [unit] The hero laptop's simulated game (LaptopScoreSimulation): it opens at
# away 3, home 7, alternates touchdowns away first, stops short of absurd
# scores, and is in-memory only — every record readonly, nothing written.
class LaptopScoreSimulationTest < ActiveSupport::TestCase
  setup do
    @game = games(:future_game)
    @sim = LaptopScoreSimulation.new(@game)
  end

  def scores = @sim.frames.map { |f| [f.game.away_score, f.game.home_score] }

  test "opens at away 3, home 7, in progress, with the field goal and the touchdown that made it" do
    opening = @sim.opening
    assert_equal 0, opening.index
    assert_equal [3, 7], [opening.game.away_score, opening.game.home_score]
    assert opening.game.live?, "drawn as a game being played"
    assert_nil opening.goal, "the opening frame announces nothing"
    labels = opening.game.goals.map { |g| [g.team_slug, g.scoring_label, g.points] }
    assert_equal [[@game.away_team_slug, "Field Goal", 3], [@game.home_team_slug, "Touchdown", 7]], labels
  end

  test "six touchdowns, alternating sides away first, then it loops; never past 45" do
    assert_equal [[3, 7], [10, 7], [10, 14], [17, 14], [17, 21], [24, 21], [24, 28]], scores
    assert_equal LaptopScoreSimulation::TOUCHDOWNS + 1, @sim.frames.size
    scorers = @sim.frames.drop(1).map { |f| f.team.slug }
    assert_equal [@game.away_team_slug, @game.home_team_slug] * 3, scorers
    @sim.frames.drop(1).each do |frame|
      assert_equal "touchdown", frame.goal.scoring_type
      assert_equal "Touchdown", frame.goal.scoring_label
      assert_equal 7, frame.goal.points
      assert_includes frame.game.goals, frame.goal, "the rail lists the touchdown it just scored"
    end
    assert_operator scores.flatten.max, :<=, 45
  end

  test "the clock runs and the ball moves from frame to frame" do
    clocks = @sim.frames.map { |f| f.game.period_clock_label }
    assert_equal clocks.uniq.size, clocks.size, "a fresh clock every frame"
    assert_equal "Q1 · 4:12", clocks.first
    balls = @sim.frames.map { |f| f.game.possession_team_slug }
    assert_equal [@game.away_team_slug, @game.home_team_slug], balls.first(2), "the side that scores next has the ball"
  end

  test "nothing is written: every record is readonly and the real game is untouched" do
    before = @game.reload.attributes
    assert_no_difference -> { Goal.count } do
      @sim.frames.each do |frame|
        assert frame.game.readonly?
        frame.game.goals.each { |goal| assert goal.readonly? }
        assert_raises(ActiveRecord::ReadOnlyRecord) { frame.game.save! }
        assert_raises(ActiveRecord::ReadOnlyRecord) { frame.goal.save! } if frame.goal
      end
    end
    assert_equal before, @game.reload.attributes
    assert_equal "scheduled", @game.status
  end

  test "the label is one constant" do
    assert_equal "Simulated preview", LaptopScoreSimulation::LABEL
    assert_equal LaptopScoreSimulation::LABEL, @sim.label
  end
end
