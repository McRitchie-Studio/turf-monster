require "test_helper"
require "turbo/broadcastable/test_helper"

# [integration] The dev score injectors, across their full effect: an HTTP POST
# in, a real Goal row plus a re-scored game plus a websocket broadcast out.
#
# These buttons exist to prove the live UX, and they can only prove it by
# entering the pipeline at the same point a real scoring play does. So this
# tests that they DO — not that they render a toast.
class DevLiveScoresTest < ActionDispatch::IntegrationTest
  # Turbo's own helper, not ActionCable::TestHelper. Turbo broadcasts do not
  # register with the raw ActionCable assertions in this setup — asserting
  # through the layer that actually emits the <turbo-stream> elements is both
  # correct and a truer statement of what the page receives.
  include Turbo::Broadcastable::TestHelper

  setup do
    @home = teams(:team_a)
    @away = teams(:team_b)
    @away.update!(league: "nfl", sport: "football")
    @game = Game.create!(
      home_team_slug: @home.slug, away_team_slug: @away.slug,
      season_year: 2026, season_type: 1, week: 4, status: "in_progress"
    )
  end

  test "each scoring type records its own point value" do
    { "touchdown" => 6, "field_goal" => 3, "two_point" => 2, "pat" => 1, "safety" => 2 }
      .each_with_index do |(type, points), index|
        post dev_live_scores_record_path,
             params: { game_slug: @game.slug, team_slug: @home.slug, scoring_type: type },
             as: :json

        assert_response :success
        body = JSON.parse(response.body)
        assert body["success"]
        assert_equal points, body["goal"]["points"]
        assert_equal type, body["goal"]["scoring_type"]
        assert_equal index + 1, @game.reload.goals.count
      end

    assert_equal 14, @game.reload.home_score
  end

  # Two streams, because a scoring event is two distinct pieces of news: the
  # board's new score (an update to nfl_live_scoreboard) and the event itself
  # (an append to nfl_live_event_feed, which the page animates).
  test "a recorded score reaches the live board over the websocket" do
    assert_turbo_stream_broadcasts("nfl_live", count: 2) do
      post dev_live_scores_record_path,
           params: { game_slug: @game.slug, team_slug: @home.slug, scoring_type: "touchdown" },
           as: :json
    end
  end

  test "clearing a game takes it back to kickoff" do
    @game.goals.create!(team_slug: @home.slug, points: 6, scoring_type: "touchdown")
    @game.goals.create!(team_slug: @away.slug, points: 3, scoring_type: "field_goal")
    @game.update!(status: "completed", status_detail: "Final", period: 4, clock: "0:00")

    post dev_live_scores_clear_game_path, params: { game_slug: @game.slug }, as: :json

    assert_response :success
    @game.reload
    assert_equal 0, @game.goals.count
    assert_equal 0, @game.home_score
    assert_equal 0, @game.away_score
    assert_equal "scheduled", @game.status
    assert_nil @game.status_detail
    assert_nil @game.period
  end

  # Clearing ten goals one at a time would fire ten recomputations and ten
  # broadcasts, so every viewer would watch the score count backwards. One bulk
  # delete, one recompute, one pair of broadcasts.
  test "clearing broadcasts once, not once per goal" do
    5.times { @game.goals.create!(team_slug: @home.slug, points: 6, scoring_type: "touchdown") }

    assert_turbo_stream_broadcasts("nfl_live", count: 1) do
      post dev_live_scores_clear_game_path, params: { game_slug: @game.slug }, as: :json
    end
  end

  # Conclude goes through Game#conclude!, the SAME path the poller takes on a
  # FINAL from the feed — so the button reveals the real final broadcast rather
  # than a mock of one. All four consequences, because a copy that forgets one
  # is a game that reads final on one surface and live on another.
  test "concluding a game marks it final and fans out every consequence" do
    slate = slates(:one)
    matchup = SlateMatchup.create!(slate: slate, team_slug: @home.slug,
                                   opponent_team_slug: @away.slug, game_slug: @game.slug,
                                   slug: "sm-conclude", rank: 1)
    @game.goals.create!(team_slug: @home.slug, points: 6, scoring_type: "touchdown")

    post dev_live_scores_conclude_game_path, params: { game_slug: @game.slug }, as: :json

    assert_response :success
    @game.reload
    assert_equal "completed", @game.status
    assert_equal "Final", @game.status_detail
    assert_equal "completed", matchup.reload.status
    assert_equal 6, @game.home_score, "concluding must not disturb the score"
  end

  test "concluding broadcasts the final graphic to the live board" do
    assert_turbo_stream_broadcasts("nfl_live", count: 2) do
      post dev_live_scores_conclude_game_path, params: { game_slug: @game.slug }, as: :json
    end
  end

  test "rejects an unknown scoring type rather than scoring something arbitrary" do
    post dev_live_scores_record_path,
         params: { game_slug: @game.slug, team_slug: @home.slug, scoring_type: "hail_mary" },
         as: :json

    assert_response :unprocessable_entity
    assert_equal 0, @game.reload.goals.count
  end

  test "rejects an unknown game or team" do
    post dev_live_scores_record_path,
         params: { game_slug: "nope", team_slug: @home.slug, scoring_type: "touchdown" }, as: :json
    assert_response :not_found

    post dev_live_scores_record_path,
         params: { game_slug: @game.slug, team_slug: "nope", scoring_type: "touchdown" }, as: :json
    assert_response :unprocessable_entity
  end

  # An injected goal carries no external_id, so the poller — which only ever
  # reconciles rows carrying an ESPN play id — leaves it alone. Without that,
  # the next cycle would read an injected touchdown as a withdrawn play and
  # delete it out from under whoever is watching.
  test "an injected goal is invisible to the poller's reconciliation" do
    post dev_live_scores_record_path,
         params: { game_slug: @game.slug, team_slug: @home.slug, scoring_type: "touchdown" },
         as: :json

    injected = @game.reload.goals.sole
    assert_nil injected.external_id
    assert_equal 0, @game.goals.where.not(external_id: nil).count
  end
end
