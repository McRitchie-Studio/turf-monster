require "test_helper"

# Contest#score_entries! on a SPAN slate loads the slate's team view ONCE.
#
# Every Selection#compute_points! on a span asks the contest whether it is
# multi-week and which games its team plays, and each answer was a fresh
# Slate#matchups_by_team load (one slate_matchups, two teams and one games
# query). Measured 2026-10-14 on the rehearsal slate (NFL 2026 Preseason Weeks
# 3-4, two entries): 144 of the 251 queries one scoring play cost, three loads
# per selection. A production game day pays that per entry per goal.
#
# Nothing inside score_entries! writes a slate_matchup, so one load taken at
# the top answers every selection exactly as a fresh load would. These tests
# hold both halves: the scores are the same, and the load happens once.
class SpanScoreEntriesQueryTest < ActiveSupport::TestCase
  setup do
    @contest = contests(:one)
    @span = Slate.create!(name: "NFL 2026 Weeks 1-2", slug: "nfl-2026-weeks-1-2-q", week: 1)
    {
      "team-a" => [2.0, [2, 3]],
      "team-b" => [3.0, [1, nil]],
      "team-c" => [1.5, [nil, nil]]
    }.each do |team, (turf, goals)|
      goals.each_with_index do |g, i|
        SlateMatchup.create!(slate: @span, team_slug: team, opponent_team_slug: "team-f",
                             game_slug: "#{team}-wk#{i + 1}-#{SecureRandom.hex(3)}", week: i + 1,
                             expected_score: 20.0, turf_score: turf, rank: 1, goals: g, status: "pending")
      end
    end
    @contest.update!(slate: @span)
    @entry = entries(:one)
    @entry.update_columns(status: "complete")
    @entry.selections.destroy_all
    %w[team-a team-b team-c].each do |team|
      Selection.create!(entry: @entry, slate_matchup: @span.matchups_by_team[team].first)
    end
  end

  def matchup_loads
    count = 0
    sub = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      count += 1 if payload[:sql].to_s.match?(/\ASELECT "slate_matchups"\.\* FROM "slate_matchups" WHERE "slate_matchups"\."slate_id"/)
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(sub)
  end

  test "a span re-score loads the slate's team view once, not three times per selection" do
    contest = Contest.find(@contest.id)

    loads = matchup_loads { contest.score_entries! }

    assert_equal 1, loads, "one matchups_by_team load for the whole re-score"
  end

  test "the scores are the ones a fresh load per selection gives" do
    Contest.find(@contest.id).score_entries!

    # team-a (2+3)x2.0 = 10; team-b 1x3.0 = 3; team-c has no result yet, so its
    # points stay nil and contribute 0.
    assert_equal 13.0, @entry.reload.score
    fresh = @entry.selections.reload.to_h { |s| [s.slate_matchup.team_slug, Selection.find(s.id).computed_points] }
    assert_equal({ "team-a" => 10.0, "team-b" => 3.0, "team-c" => nil }, fresh.transform_values { _1&.to_f })
  end

  test "the snapshot ends with the re-score, so a later goal is read fresh" do
    contest = Contest.find(@contest.id)
    contest.score_entries!
    @span.slate_matchups.where(team_slug: "team-c", week: 1).update_all(goals: 4)

    contest.score_entries!

    assert_equal 13.0 + (4 * 1.5), @entry.reload.score
  end

  test "the snapshot is released when the re-score raises" do
    slate = @span
    assert_raises(RuntimeError) { slate.with_matchups_by_team_snapshot { raise "boom" } }

    loads = matchup_loads { slate.matchups_by_team }
    assert_equal 1, loads, "no stale snapshot survives a raise"
  end
end
