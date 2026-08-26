require "test_helper"

# [integration] One polling cycle, across its whole I/O boundary: an ESPN
# payload in, Game + Goal rows and SlateMatchup propagation out.
#
# The HTTP client is stubbed — the point is the seam BELOW it. What the network
# actually returns is pinned by the unit tests over the parse seams.
class NflLiveScoresPollTest < ActionDispatch::IntegrationTest
  # Stands in for Nfl::Espn::Client. Records what was asked for, so a test can
  # assert that a summary was NOT fetched for a game whose score did not move —
  # the optimisation the whole polling budget rests on.
  class StubClient
    attr_reader :summary_calls

    def initialize(scoreboard:, summaries: {})
      @scoreboard = scoreboard
      @summaries = summaries
      @summary_calls = []
    end

    def scoreboard(**) = @scoreboard

    def summary(event_id:)
      @summary_calls << event_id
      @summaries.fetch(event_id, { "scoringPlays" => [] })
    end
  end

  # Only `team_a` carries league: nfl in the shared fixtures, and TeamMap looks
  # inside Team.nfl on purpose — so a non-NFL team sharing an abbreviation can
  # never be picked up by this feed. Enrolling the others here (inside the test
  # transaction) is cheaper than widening a fixture every other suite reads.
  setup do
    @home = teams(:team_a)
    @away = teams(:team_b)
    [@away, teams(:team_c), teams(:team_d)].each do |team|
      team.update!(league: "nfl", sport: "football")
    end
    @slot = Nfl::LiveScores::PollCycle::Slot.new(year: 2026, season_type: 1, week: 4)
  end

  test "writes a game, its scoring events, and the resulting score" do
    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    game = Game.find_by(external_id: "EV1")
    assert_not_nil game
    assert_equal "team-a-vs-team-b-pre4", game.slug
    assert_equal 10, game.home_score
    assert_equal 7, game.away_score
    assert_equal 3, game.goals.count
    assert_equal 1, result.games_seen
    assert_empty result.anomalies
    assert_equal %w[score score score], result.changes.map(&:kind)
  end

  # The idempotency guarantee the twelve-hour loop depends on: run it again and
  # nothing is written, because every play carries ESPN's own id under a unique
  # index.
  test "a second identical cycle writes nothing" do
    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_no_difference -> { Goal.count } do
      result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)
      assert result.quiet?
      assert_empty result.changes
    end
  end

  # ESPN withdraws plays when a touchdown is overturned on review. A Goal that
  # outlived its play would leave a contest scored on points nobody scored.
  test "a play the feed withdraws is removed and the score comes back down" do
    full = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: full)
    assert_equal 10, Game.find_by(external_id: "EV1").home_score

    # Same game, minus the touchdown, with the score corrected to match.
    reversed = StubClient.new(
      scoreboard: scoreboard(home: 3, away: 7),
      summaries: { "EV1" => { "scoringPlays" => summary["scoringPlays"].reject { |p| p["id"] == "P1" } } }
    )
    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: reversed)

    game = Game.find_by(external_id: "EV1")
    assert_equal 3, game.home_score
    assert_equal 2, game.goals.count
    assert_includes result.changes.map(&:kind), "reversed"
  end

  # The expensive half of a cycle is the per-game summary request. A game whose
  # score has not moved must not cost one — this is what keeps a full Sunday
  # slate at roughly one request per cycle.
  test "spends no summary request on a game whose score has not moved" do
    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)
    assert_equal ["EV1"], client.summary_calls

    quiet = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: quiet)

    assert_empty quiet.summary_calls
  end

  test "propagates the score onto every slate matchup for that game" do
    slate = slates(:one)
    game_slug = "team-a-vs-team-b-pre4"
    home_matchup = SlateMatchup.create!(slate: slate, team_slug: @home.slug,
                                        opponent_team_slug: @away.slug, game_slug: game_slug,
                                        slug: "sm-home-pre4", rank: 1)
    away_matchup = SlateMatchup.create!(slate: slate, team_slug: @away.slug,
                                        opponent_team_slug: @home.slug, game_slug: game_slug,
                                        slug: "sm-away-pre4", rank: 2)

    client = StubClient.new(scoreboard: scoreboard(home: 10, away: 7), summaries: { "EV1" => summary })
    Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_equal 10, home_matchup.reload.goals
    assert_equal 7, away_matchup.reload.goals
  end

  # A game marked final bypasses the Goal callbacks, so the matchup flip has to
  # be explicit — the same reason the admin console's complete_game does it.
  test "a completed game flips its matchups to completed" do
    slate = slates(:one)
    matchup = SlateMatchup.create!(slate: slate, team_slug: @home.slug, opponent_team_slug: @away.slug,
                                   game_slug: "team-a-vs-team-b-pre4", slug: "sm-final-pre4", rank: 1)

    client = StubClient.new(
      scoreboard: scoreboard(home: 10, away: 7, state: "post", completed: true),
      summaries: { "EV1" => summary }
    )
    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_equal "completed", Game.find_by(external_id: "EV1").status
    assert_equal "completed", matchup.reload.status
    assert_includes result.changes.map(&:kind), "final"
  end

  # An unmappable team is REPORTED, never silently skipped. A team that quietly
  # never scores is the worst failure available in a feed that settles money.
  test "an unknown team is reported as an anomaly rather than dropped in silence" do
    board = scoreboard(home: 10, away: 7)
    board["events"][0]["competitions"][0]["competitors"][0]["team"]["abbreviation"] = "ZZZ"
    client = StubClient.new(scoreboard: board)

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_equal ["unknown_team"], result.anomalies.map(&:kind)
    assert_equal 0, Game.where(external_id: "EV1").count
  end

  # When our summed events and the feed's total disagree, something was skipped.
  # Saying so beats serving a confidently wrong scoreboard.
  test "reports drift when our summed score disagrees with the feed" do
    client = StubClient.new(
      scoreboard: scoreboard(home: 99, away: 7),
      summaries: { "EV1" => summary }
    )

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    assert_equal ["score_drift"], result.anomalies.map(&:kind)
    assert_match(/ESPN 7-99/, result.anomalies.first.detail)
  end

  test "one game failing to fetch does not abort the rest of the cycle" do
    board = scoreboard(home: 10, away: 7)
    board["events"] << board["events"].first.deep_dup.tap { |e| e["id"] = "EV2" }
    board["events"][1]["competitions"][0]["competitors"][0]["team"]["abbreviation"] = "TMC"
    board["events"][1]["competitions"][0]["competitors"][1]["team"]["abbreviation"] = "TMD"

    client = StubClient.new(scoreboard: board, summaries: { "EV1" => summary })
    def client.summary(event_id:)
      raise Nfl::Espn::Client::Error, "boom" if event_id == "EV1"

      super
    end

    result = Nfl::LiveScores::PollCycle.call(slot: @slot, client: client)

    # EV1 reports fetch_failed. EV2 goes on to be processed — which is the point
    # of the test — and reports drift of its own, because the stub returns it no
    # scoring plays to back its scoreboard total. Both anomalies are correct, so
    # this asserts the first is PRESENT rather than that it is alone.
    assert_includes result.anomalies.map(&:kind), "fetch_failed"
    assert_equal 2, result.games_seen
    assert_not_nil Game.find_by(external_id: "EV2")
  end

  private

  def scoreboard(home:, away:, state: "in", completed: false)
    {
      "events" => [{
        "id" => "EV1",
        "date" => "2026-08-27T23:00Z",
        "season" => { "year" => 2026, "type" => 1 },
        "week" => { "number" => 4 },
        "competitions" => [{
          "status" => { "period" => 3, "displayClock" => "8:42",
                        "type" => { "state" => state, "completed" => completed, "shortDetail" => "Q3 8:42" } },
          "competitors" => [
            { "homeAway" => "home", "score" => home.to_s, "team" => { "abbreviation" => "TMA" } },
            { "homeAway" => "away", "score" => away.to_s, "team" => { "abbreviation" => "TMB" } }
          ]
        }]
      }]
    }
  end

  # Home 10 (TD+kick, then FG), away 7 (TD+kick).
  def summary
    {
      "scoringPlays" => [
        play("P1", "TMA", home: 7,  away: 0, type: "TD"),
        play("P2", "TMB", home: 7,  away: 7, type: "TD"),
        play("P3", "TMA", home: 10, away: 7, type: "FG")
      ]
    }
  end

  def play(id, team, home:, away:, type:)
    {
      "id" => id, "type" => { "abbreviation" => type },
      "team" => { "abbreviation" => team },
      "homeScore" => home, "awayScore" => away,
      "period" => { "number" => 2 }, "clock" => { "displayValue" => "5:28" },
      "text" => "#{team} scored"
    }
  end
end
