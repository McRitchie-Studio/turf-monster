require "test_helper"
require "turbo/broadcastable/test_helper"

# [integration] The play-by-play through one polling cycle: a scoreboard (and
# sometimes a summary) in, GamePlay rows and two small broadcasts out.
#
# What the cycle does about SCORES is pinned by nfl_live_scores_poll_test.rb.
# These pin the half stacked on top of it — and, above all, that the half on
# top can never cost the half underneath anything.
class NflLivePlaysPollTest < ActionDispatch::IntegrationTest
  include Turbo::Broadcastable::TestHelper

  class StubClient
    attr_reader :summary_calls

    def initialize(scoreboard:, summaries: {}, summary_error: nil)
      @scoreboard = scoreboard
      @summaries = summaries
      @summary_error = summary_error
      @summary_calls = []
    end

    def scoreboard(**) = @scoreboard

    def summary(event_id:)
      @summary_calls << event_id
      raise @summary_error if @summary_error

      @summaries.fetch(event_id) { { "scoringPlays" => [] } }
    end
  end

  setup do
    [teams(:team_b), teams(:team_c), teams(:team_d)].each { |team| team.update!(league: "nfl", sport: "football") }
    @slot = Nfl::LiveScores::PollCycle::Slot.new(year: 2026, season_type: 1, week: 4)
  end

  def cycle(client) = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)
  def game = Game.find_by(external_id: "EV1")

  test "stores the scoreboard's last play and each side's timeouts" do
    result = cycle(StubClient.new(scoreboard: scoreboard(last: "EV1101"), summaries: { "EV1" => drives("EV1101") }))

    assert_empty result.anomalies
    play = game.plays.sole
    assert_equal "EV1101", play.external_id
    assert_equal 101, play.sequence
    assert_equal "team-b", play.team_slug
    assert_equal [2, 3], [game.home_timeouts, game.away_timeouts]
  end

  # THE GUARANTEE THE TIGHT LOOP RESTS ON: run it again, write nothing.
  test "a second identical cycle writes no play and fetches no summary" do
    client = StubClient.new(scoreboard: scoreboard(last: "EV1101"), summaries: { "EV1" => drives("EV1101") })
    cycle(client)
    calls = client.summary_calls.length

    assert_no_difference -> { GamePlay.count } do
      cycle(client)
    end
    assert_equal calls, client.summary_calls.length, "a play we already hold must not cost a summary"
  end

  # The focus game is the one people are watching, so a play the scoreboard
  # names and we do not hold buys ONE summary — which fills in everything
  # since the last look, with the clock and the down on every line.
  test "the focus game is backfilled from the summary, with no gaps" do
    client = StubClient.new(
      scoreboard: scoreboard(last: "EV1103"),
      summaries: { "EV1" => drives("EV1101", "EV1102", "EV1103") }
    )

    cycle(client)

    assert_equal %w[EV1101 EV1102 EV1103], game.plays.order(:sequence).pluck(:external_id)
    assert_equal ["EV1"], client.summary_calls
    assert_equal "2nd & 4 at TMA 30", game.plays.find_by(external_id: "EV1102").down_distance
    assert_equal "timeout", game.plays.find_by(external_id: "EV1103").kind
  end

  # A full Sunday is nine games at once. Only the one the board leads with
  # may spend a summary on its plays; the rest ride the scoreboard for free.
  test "a live game that is not the focus game costs no summary" do
    board = scoreboard(last: "EV1101")
    board["events"] << second_event(last: "EV2201")
    client = StubClient.new(scoreboard: board, summaries: { "EV1" => drives("EV1101") })

    cycle(client)

    assert_equal ["EV1"], client.summary_calls
    other = Game.find_by(external_id: "EV2")
    assert_equal ["EV2201"], other.plays.pluck(:external_id)
    assert_nil other.plays.sole.down_distance, "the scoreboard's copy has no down of its own"
  end

  # The scoreboard's copy knows less than the summary's. Arriving second, it
  # must not put the game's CURRENT clock on a play from two minutes ago.
  test "the scoreboard's copy never overwrites what the summary said" do
    cycle(StubClient.new(scoreboard: scoreboard(last: "EV1101"), summaries: { "EV1" => drives("EV1101") }))
    assert_equal "9:01", game.plays.sole.clock

    cycle(StubClient.new(scoreboard: scoreboard(last: "EV1101", clock: "7:00")))

    assert_equal "9:01", game.plays.sole.clock
    assert_equal "1st & 10 at TMA 25", game.plays.sole.down_distance
  end

  # THE ONE THAT MATTERS MOST. The play-by-play is something to watch; contests
  # are paid on the score. A summary that will not arrive must cost the feed a
  # cycle and the score nothing.
  test "a failed play fetch is reported and leaves the score cycle whole" do
    client = StubClient.new(
      scoreboard: scoreboard(last: "EV1101"),
      summary_error: Nfl::Espn::Client::Error.new("ESPN /summary returned HTTP 503")
    )

    result = cycle(client)

    assert_equal %w[plays_fetch_failed], result.anomalies.map(&:kind)
    assert_equal "in_progress", game.status
    assert_equal 0, game.plays.count
  end

  test "a summary with no drives block falls back to the scoreboard's play" do
    client = StubClient.new(scoreboard: scoreboard(last: "EV1101"), summaries: { "EV1" => { "scoringPlays" => [] } })

    result = cycle(client)

    assert_empty result.anomalies
    assert_equal ["EV1101"], game.plays.pluck(:external_id)
  end

  test "a scheduled game stores no play" do
    cycle(StubClient.new(scoreboard: scoreboard(last: nil, state: "pre")))

    assert_equal 0, GamePlay.count
    assert_nil game.home_timeouts
  end

  # ── what an open board is told ───────────────────────────────────────────

  test "a new play updates the game's status pane and its play feed, and nothing else" do
    contest = live_contest_on("team-a-vs-team-b-pre4")
    client = StubClient.new(scoreboard: scoreboard(last: "EV1101"), summaries: { "EV1" => drives("EV1101") })

    streams = capture_turbo_stream_broadcasts([contest, :live]) { cycle(client) }

    assert_equal %w[game_team-a-vs-team-b-pre4_plays game_team-a-vs-team-b-pre4_status],
                 streams.map { |stream| stream["target"] }.sort
    assert_equal %w[update], streams.map { |stream| stream["action"] }.uniq
    feed = streams.find { |stream| stream["target"].end_with?("_plays") }.to_html
    assert_includes feed, "A.Runner up the middle for 4 yards."
  end

  test "a cycle in which nothing moved tells the board nothing" do
    contest = live_contest_on("team-a-vs-team-b-pre4")
    client = StubClient.new(scoreboard: scoreboard(last: "EV1101"), summaries: { "EV1" => drives("EV1101") })
    # Captured, not assert_no_turbo_stream_broadcasts: that helper counts the
    # stream's whole history, and the first cycle rightly broadcast.
    capture_turbo_stream_broadcasts([contest, :live]) { cycle(client) }

    assert_empty capture_turbo_stream_broadcasts([contest, :live]) { cycle(client) }
  end

  # The clock runs between snaps, and a timeout is spent without a new play
  # arriving in the same cycle. Either is worth a redraw.
  test "a spent timeout alone redraws the board" do
    contest = live_contest_on("team-a-vs-team-b-pre4")
    client = StubClient.new(scoreboard: scoreboard(last: "EV1101"), summaries: { "EV1" => drives("EV1101") })
    cycle(client)

    streams = capture_turbo_stream_broadcasts([contest, :live]) do
      cycle(StubClient.new(scoreboard: scoreboard(last: "EV1101", home_timeouts: 1)))
    end

    assert_equal 2, streams.length
    assert_equal 1, game.home_timeouts
  end

  private

  def live_contest_on(game_slug)
    contest = contests(:one)
    contest.update!(starts_at: 1.hour.ago, status: "open")
    slate_matchups(:m1).update!(game_slug: game_slug)
    contest
  end

  def scoreboard(last:, state: "in", clock: "8:42", home_timeouts: 2)
    competition = {
      "status" => { "period" => 3, "displayClock" => clock,
                    "type" => { "state" => state, "completed" => false, "shortDetail" => "Q3 #{clock}" } },
      "competitors" => [
        { "id" => "1", "homeAway" => "home", "score" => "0", "team" => { "abbreviation" => "TMA" } },
        { "id" => "2", "homeAway" => "away", "score" => "0", "team" => { "abbreviation" => "TMB" } }
      ]
    }
    if last
      competition["situation"] = {
        "lastPlay" => { "id" => last, "type" => { "text" => "Rush" }, "text" => "A.Runner up the middle for 4 yards.",
                        "team" => { "id" => "2" } },
        "downDistanceText" => "2nd & 6 at TMA 29", "possessionText" => "TMA 29", "possession" => "2",
        "homeTimeouts" => home_timeouts, "awayTimeouts" => 3
      }
    end

    { "events" => [{ "id" => "EV1", "date" => "2026-08-27T23:00Z", "season" => { "year" => 2026, "type" => 1 },
                     "week" => { "number" => 4 }, "competitions" => [competition] }] }
  end

  # A second live game in the same slot, kicking off LATER — so the first one
  # is the game the board leads with.
  def second_event(last:)
    {
      "id" => "EV2", "date" => "2026-08-28T02:00Z", "season" => { "year" => 2026, "type" => 1 },
      "week" => { "number" => 4 },
      "competitions" => [{
        "status" => { "period" => 1, "displayClock" => "12:00",
                      "type" => { "state" => "in", "completed" => false, "shortDetail" => "Q1 12:00" } },
        "competitors" => [
          { "id" => "3", "homeAway" => "home", "score" => "0", "team" => { "abbreviation" => "TMC" } },
          { "id" => "4", "homeAway" => "away", "score" => "0", "team" => { "abbreviation" => "TMD" } }
        ],
        "situation" => { "lastPlay" => { "id" => last, "type" => { "text" => "Kickoff" }, "text" => "Kickoff.",
                                          "team" => { "id" => "4" } } }
      }]
    }
  end

  PLAYS = {
    "EV1101" => { "type" => "Rush", "text" => "A.Runner up the middle for 4 yards.", "clock" => "9:01",
                  "down" => "1st & 10 at TMA 25" },
    "EV1102" => { "type" => "Pass Incompletion", "text" => "B.Passer pass incomplete.", "clock" => "8:50",
                  "down" => "2nd & 4 at TMA 30" },
    "EV1103" => { "type" => "Timeout", "text" => "Timeout #1 by TMA at 08:42.", "clock" => "8:42", "down" => nil }
  }.freeze

  def drives(*ids)
    plays = ids.map do |id|
      spec = PLAYS.fetch(id)
      { "id" => id, "type" => { "text" => spec["type"] }, "text" => spec["text"],
        "period" => { "number" => 3 }, "clock" => { "displayValue" => spec["clock"] },
        "homeScore" => 0, "awayScore" => 0,
        "start" => { "downDistanceText" => spec["down"], "team" => { "id" => "2" } }.compact }
    end

    { "scoringPlays" => [],
      "drives" => { "previous" => [{ "id" => "D1", "team" => { "id" => "2", "abbreviation" => "TMB" }, "plays" => plays }] } }
  end
end
