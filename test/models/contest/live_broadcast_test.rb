require "test_helper"
# turbo-rails 2.x only require-s this helper lazily inside its on_load(:action_cable)
# hook, which has not fired when this file loads — so require it explicitly before
# the include below (otherwise: uninitialized constant Turbo::Broadcastable::TestHelper).
require "turbo/broadcastable/test_helper"

class Contest::LiveBroadcastTest < ActiveSupport::TestCase
  include Turbo::Broadcastable::TestHelper

  setup do
    @contest = contests(:one) # turf_totals, slate :one
    @contest.update!(starts_at: 1.hour.ago, status: "open") # → live? true
    @game = Game.create!(home_team_slug: "team-a", away_team_slug: "team-b",
                         kickoff_at: 30.minutes.ago, status: "scheduled")
    slate_matchups(:m1).update!(game_slug: @game.slug) # links the game to the contest's slate
  end

  test "goal_scored fires leaderboard + games + goal-feed broadcasts on the contest's live stream" do
    goal = Goal.new(game_slug: @game.slug, team_slug: "team-a")
    # Call the broadcaster directly (deterministic — doesn't depend on
    # after_create_commit firing under transactional fixtures). 4 broadcasts:
    # goal-feed append + leaderboard + games strip + focus panel. The focus panel
    # is its own target because it is not adjacent to the strip in the layout —
    # the strip runs across the top, the focused game sits above chat in the left
    # column — and one stream target cannot span both.
    #
    # THE COUNT IS THE POINT. Every one of these broadcasts is individually
    # rescued, so a partial that raises in broadcast context (no controller
    # ivars, no current_user) does not fail loudly — it just never arrives, and
    # the number here is the only thing that notices.
    assert_turbo_stream_broadcasts([@contest, :live], count: 4) do
      Contest::LiveBroadcast.goal_scored(goal)
    end
  end

  test "affected_contests includes a live contest and excludes a settled one" do
    assert_includes Contest::LiveBroadcast.affected_contests(@game), @contest
    @contest.update!(status: "settled")
    assert_not_includes Contest::LiveBroadcast.affected_contests(@game), @contest
  end

  test "score_changed game_completed fires the FINAL feed + leaderboard + games + focus" do
    assert_turbo_stream_broadcasts([@contest, :live], count: 4) do
      Contest::LiveBroadcast.score_changed(@game, event: :game_completed)
    end
  end

  test "score_changed goal_removed fires leaderboard + games + focus (no toast feed)" do
    assert_turbo_stream_broadcasts([@contest, :live], count: 3) do
      Contest::LiveBroadcast.score_changed(@game, event: :goal_removed)
    end
  end
end
