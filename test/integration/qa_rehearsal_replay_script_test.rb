# frozen_string_literal: true

require "test_helper"

# Step 3's replay script, RUN against a real database: the Ruby the dyno runs,
# evaluated here, through the real Goal callbacks, the contest re-score and both
# broadcasts. What it must keep, whatever the pace (the fidelity criteria):
#   * every captured play is re-created through Goal.create!;
#   * in kickoff-then-game-clock order, so simultaneous games interleave;
#   * each game concludes right after its own last play;
#   * the contest re-scores through the real path, and the catch-up check
#     proves it before the step may hand on to conclude.
class QaRehearsalReplayScriptTest < ActiveSupport::TestCase
  Driver = TurfMonster::QaRehearsal::Driver

  setup do
    @slate = Slate.create!(name: Driver::SLATE_NAME, slug: "qa-replay-slate", week: 3)
    kickoff = 2.hours.ago
    @g1 = Game.create!(home_team_slug: "team-c", away_team_slug: "team-d", kickoff_at: kickoff, status: "completed")
    @g2 = Game.create!(home_team_slug: "team-e", away_team_slug: "team-f", kickoff_at: kickoff, status: "completed")
    @matchups = {}
    [[@g1, "team-c", "team-d"], [@g2, "team-e", "team-f"]].each do |game, home, away|
      [[home, away], [away, home]].each do |team, opp|
        @matchups[team] = SlateMatchup.create!(slate: @slate, team_slug: team, opponent_team_slug: opp,
                                               game_slug: game.slug, week: 3, expected_score: 20.0,
                                               turf_score: 2.0, rank: 1, status: "pending")
      end
    end

    # The board as the poller left it: every play present, in no useful order.
    [
      [@g1, "team-c", 9, "touchdown", 7],
      [@g2, "team-f", 3, "field_goal", 3],
      [@g1, "team-d", 41, "field_goal", 3],
      [@g2, "team-e", 22, "touchdown", 7],
      [@g1, "team-c", 55, "safety", 2]
    ].each do |game, team, minute, type, points|
      Goal.create!(game_slug: game.slug, team_slug: team, minute: minute, scoring_type: type, points: points)
    end

    @contest = contests(:one)
    @contest.update!(slate: @slate)
    @contest.update_columns(starts_at: 3.hours.ago, status: "open")
    @entry = entries(:one)
    @entry.update_columns(status: "complete", score: 99)
    @entry.selections.destroy_all
    Selection.create!(entry: @entry, slate_matchup: @matchups["team-c"])
    Selection.create!(entry: @entry, slate_matchup: @matchups["team-f"])
  end

  def run_script(pace = nil)
    script = Driver.new(io: StringIO.new).replay_script(pace)
    out, = capture_io { Object.new.instance_eval(script) }
    out
  end

  test "every play is re-laid in game-clock order, interleaved, each game final after its last" do
    out = run_script

    order = out.lines.grep(/replay: +\d+\/5|replay: FINAL/).map(&:strip)
    # minute 3 (g2), 9 (g1), 22 (g2) -> g2 is done, 41 (g1), 55 (g1) -> g1 done
    assert_equal 7, order.size, "five plays re-created, two games concluded"
    assert_match(%r{1/5\s+TEAM\s+field_goal\s+\+3}, order[0])
    assert_match(%r{2/5\s+TEAM\s+touchdown\s+\+7\s+TEA 0-7}, order[1])
    assert_match(%r{3/5\s+TEAM\s+touchdown\s+\+7}, order[2])
    assert_equal "replay: FINAL  #{@g2.slug}", order[3], "g2 concludes right after ITS last play, mid-replay"
    assert_equal "replay: FINAL  #{@g1.slug}", order.last

    assert_equal 5, Goal.where(game_slug: [@g1.slug, @g2.slug]).count
    assert_equal [9, 3], [@g1.reload.home_score, @g1.away_score]
    assert_equal [7, 3], [@g2.reload.home_score, @g2.away_score]
    assert_equal %w[completed completed], [@g1.status, @g2.status]
  end

  test "the contest re-scores through the real path and the check says so" do
    out = run_script

    # team-c scored 9, team-f scored 3, each at x2.0.
    assert_equal 24.0, @entry.reload.score
    assert_match(/replay: done — 5 plays, 2 games in \d+s \(work per play \d+ms mean, \d+ms p95\)/, out)
    assert_match(/replay: caught up — 5 plays on the board, 2 games final, \d+ entry score\(s\) equal a fresh recompute/, out)
  end

  test "a re-score that lags the plays fails the catch-up check instead of passing on" do
    Game.class_eval do
      alias_method :__real_score_affected_contests!, :score_affected_contests!
      define_method(:score_affected_contests!) { nil }
    end

    error = nil
    out, = capture_io do
      error = assert_raises(RuntimeError) { Object.new.instance_eval(Driver.new(io: StringIO.new).replay_script(nil)) }
    end

    assert_match(/catch-up check failed/, error.message)
    assert_match(/replay: CATCH-UP FAILED — entry #{@entry.id} in #{@contest.slug} scores 0.0, a fresh recompute gives 24.0/, out)
  ensure
    Game.class_eval do
      alias_method :score_affected_contests!, :__real_score_affected_contests!
      remove_method :__real_score_affected_contests!
    end
  end

  test "a rescued broadcast error fails the check: the log is the only thing that notices" do
    Contest::LiveBroadcast.singleton_class.class_eval do
      alias_method :__real_goal_scored, :goal_scored
      define_method(:goal_scored) { |_goal| ErrorLog.capture!(RuntimeError.new("partial raised in broadcast")) }
    end

    out, = capture_io do
      assert_raises(RuntimeError) { Object.new.instance_eval(Driver.new(io: StringIO.new).replay_script(nil)) }
    end

    assert_match(/CATCH-UP FAILED — 5 error\(s\) rescued into ErrorLog during the replay: partial raised in broadcast/, out)
  ensure
    Contest::LiveBroadcast.singleton_class.class_eval do
      alias_method :goal_scored, :__real_goal_scored
      remove_method :__real_goal_scored
    end
  end

  test "an empty board fails the check instead of reading as caught up" do
    Goal.where(game_slug: [@g1.slug, @g2.slug]).delete_all
    @contest.entries.update_all(status: "abandoned")

    out, = capture_io { assert_raises(RuntimeError) { Object.new.instance_eval(Driver.new(io: StringIO.new).replay_script(nil)) } }

    assert_match(/CATCH-UP FAILED — no plays were captured/, out)
    assert_match(/CATCH-UP FAILED — no entry in an open contest/, out)
  end
end
