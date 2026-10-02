require "test_helper"

# Contest#any_game_started? is what the contest URL routes on
# (ContestsController#show): from the first kickoff the visitor is sent to the
# live board. It must agree with Contest#games_by_phase about what "started"
# means — kickoff passed, a score on the board, or final — because the live
# board buckets its games by that same inference.
class ContestAnyGameStartedTest < ActiveSupport::TestCase
  setup do
    @contest = contests(:one)
    @game = games(:future_game)
    @game.save! # Sluggable rewrites the slug on save; settle it before pointing a matchup at it
    slate_matchups(:m3).update!(game_slug: @game.slug)
  end

  test "false while every game on the slate is still ahead" do
    assert_not @contest.any_game_started?
  end

  test "false for a slate whose matchups carry no game at all" do
    slate_matchups(:m3).update!(game_slug: nil)

    assert_not @contest.any_game_started?
  end

  test "true once one game's kickoff has passed" do
    @game.update!(kickoff_at: 1.minute.ago)

    assert @contest.any_game_started?
  end

  test "true for a game marked in progress ahead of its listed kickoff" do
    @game.update!(status: "in_progress")

    assert @contest.any_game_started?
  end

  test "true for a completed game" do
    @game.update!(status: "completed")

    assert @contest.any_game_started?
  end

  test "true once a future-dated game has a score on the board" do
    @game.goals.create!(team_slug: @game.home_team_slug, points: 3, scoring_type: "field_goal")

    assert @contest.any_game_started?
  end

  test "a started game on ANOTHER slate does not count" do
    assert games(:past_game).kickoff_at.past?, "fixture must be a started game for this to mean anything"

    assert_not @contest.any_game_started?
  end

  test "agrees with games_by_phase about which games have left upcoming" do
    assert_equal [@game], @contest.games_by_phase[:upcoming]

    @game.update!(kickoff_at: 1.minute.ago)

    assert_empty @contest.games_by_phase[:upcoming]
    assert @contest.any_game_started?
  end
end
