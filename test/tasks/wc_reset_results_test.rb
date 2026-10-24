require "test_helper"
require "rake"

# wc:reset_results — wipes a slate's simulated game results for real scoring while
# freezing (settling) alpha/test contests so their leaderboards survive.
class WcResetResultsTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("wc:reset_results")
    @task = Rake::Task["wc:reset_results"]
    @task.reenable
    @slate = slates(:one)
  end

  teardown do
    %w[SLATE_ID FREEZE CONFIRM].each { |k| ENV.delete(k) }
  end

  test "freezes snapshot contest, wipes slate games, and zeroes other open contests" do
    # OPEN contest to be zeroed — fixture `one` (slate one). Give each entry a
    # selection (distinct matchups — fixture entries share a blank slug).
    open_c = contests(:one)
    open_sels = open_c.entries.each_with_index.map do |e, i|
      e.selections.create!(slate_matchup: [slate_matchups(:m1), slate_matchups(:m2)][i])
    end

    # SNAPSHOT contest to freeze (medium tier → payouts {1 => 10000, 2 => 4000}).
    frozen = Contest.create!(name: "Alpha", slug: "alpha-x", contest_type: "medium",
                             status: "open", slate: @slate, max_entries: 9, entry_fee_cents: 1900)
    e1 = frozen.entries.create!(user: users(:alex),   status: :active)
    e2 = frozen.entries.create!(user: users(:jordan), status: :active)

    # A game on the slate + a goal, with the matchup wired to it.
    game = Game.create!(week: 1, home_team_slug: "team-a", away_team_slug: "team-b", kickoff_at: 1.day.from_now)
    matchup = slate_matchups(:m1)
    goal = Goal.create!(game_slug: game.slug, team_slug: "team-a")

    # Force a deterministic pre-task baseline via update_columns so Game/Goal
    # callbacks can't perturb what we assert against.
    matchup.update_columns(game_slug: game.slug, goals: 3)
    game.update_columns(home_score: 3, away_score: 1, status: "completed")
    open_sels.each { |s| s.update_columns(points: 5.0) }
    open_c.entries.each { |e| e.update_columns(score: 1.5) }
    e1.update_columns(score: 20.0)
    e2.update_columns(score: 10.0)

    ENV["SLATE_ID"] = @slate.id.to_s
    ENV["FREEZE"]   = frozen.id.to_s
    ENV["CONFIRM"]  = "1"
    capture_io { @task.invoke }

    # Frozen: settled, ranked, paid out on paper, score PRESERVED.
    assert frozen.reload.settled?
    assert_equal 1, e1.reload.rank
    assert_equal 2, e2.reload.rank
    assert_equal 10_000, e1.payout_cents
    assert_equal 4_000,  e2.payout_cents
    assert_equal 20.0,   e1.score

    # Games wiped clean.
    assert_nil game.reload.home_score
    assert_nil game.away_score
    assert_equal "scheduled", game.status
    assert_nil matchup.reload.goals
    assert_equal 0, Goal.where(game_slug: game.slug).count

    # Other open contest zeroed (scores + cached selection points).
    open_c.reload.entries.each do |e|
      assert_equal 0.0, e.score
      e.selections.each { |s| assert_nil s.points }
    end
  end

  test "refuses to run without CONFIRM" do
    ENV["SLATE_ID"] = @slate.id.to_s
    ENV.delete("CONFIRM")
    assert_raises(SystemExit) { capture_io { @task.invoke } }
  end
end
