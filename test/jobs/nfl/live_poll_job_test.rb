# frozen_string_literal: true

require "test_helper"

# [integration] The scheduled poller, at the seam that failed.
#
# The point of these is narrow and deliberate. PollCycle itself is exhaustively
# covered by test/integration/nfl_live_scores_poll_test.rb; what is NOT covered
# anywhere else is that something calls it WITHOUT A HUMAN, asks ESPN for the
# current slot rather than a computed one, and carries no override past the
# settled-contest refusal.
#
# Until 2026-09-30 there was no such caller at all. `bin/nfl-live-poll` was the
# only non-test one, so production contests re-scored only when an agent happened
# to run the `live-score-watch` act — and regular-season week 2 vanished when
# nobody did for six days.
class NflLivePollJobTest < ActiveSupport::TestCase
  def quiet_result
    Nfl::LiveScores::PollCycle::Result.new(
      slot: Nfl::LiveScores::PollCycle::Slot.new(year: 2026, season_type: 2, week: 4),
      games_seen: 16, changes: [], anomalies: []
    )
  end

  # NO SLOT, ON PURPOSE. A bare scoreboard request returns whatever ESPN
  # considers current, which is a far more reliable answer than anything we could
  # compute from a calendar — and a calendar that drifts is how a job polls the
  # wrong week forever without noticing.
  #
  # THE OVERRIDE MUST NEVER RIDE A SCHEDULE either. `allow_settled` exists for an
  # operator who has read the settlement seam and decided anyway; a cron has read
  # nothing, so the settled-contest refusal always applies to this job.
  test "runs a cycle against ESPN's current slot, with no slot and no override" do
    calls = []
    result = quiet_result

    Nfl::LiveScores::PollCycle.stub(:call, ->(**kwargs) { calls << kwargs; result }) do
      Nfl::LivePollJob.perform_now
    end

    assert_equal 1, calls.length
    assert_empty calls.first, "the cycle decides the slot and owns the settled-contest refusal"
    refute calls.first.key?(:allow_settled)
  end

  # A feed we do not own will have bad minutes. A scoreboard that did not arrive
  # must not become a raised exception Sidekiq retries into a third party — the
  # next tick is five minutes away and the cycle is idempotent.
  test "a scoreboard that did not arrive is logged, not raised" do
    Nfl::LiveScores::PollCycle.stub(:call, ->(**) { raise Nfl::Espn::Client::Error, "503 from ESPN" }) do
      assert_nothing_raised { Nfl::LivePollJob.perform_now }
    end
  end

  # END TO END, through the real cycle: a tick writes the scores. Without this
  # the tests above pass against a job that calls a cycle which no longer works.
  test "a tick against a live slate writes the goals" do
    teams(:team_b).update!(league: "nfl", sport: "football")

    Nfl::Espn::Client.stub(:new, StubEspnClient.new(board, summary_payload)) do
      Nfl::LivePollJob.perform_now
    end

    game = Game.find_by(external_id: "EV9")
    assert_not_nil game, "the job's cycle created the game"
    assert_equal 7, game.home_score
    assert_equal 1, game.goals.count
  end

  # And the refusal reaches the JOB, not only a direct caller: a settled contest
  # on the slot leaves the tick writing nothing.
  test "a tick against a settled contest's slot writes nothing" do
    teams(:team_b).update!(league: "nfl", sport: "football")
    SlateMatchup.create!(slate: slates(:one), team_slug: teams(:team_a).slug,
                         opponent_team_slug: teams(:team_b).slug,
                         game_slug: "team-a-vs-team-b", slug: "sm-settled", rank: 1)
    contests(:one).update!(status: "settled")

    Nfl::Espn::Client.stub(:new, StubEspnClient.new(board, summary_payload)) do
      assert_no_difference -> { Goal.count } do
        Nfl::LivePollJob.perform_now
      end
    end

    assert_nil Game.find_by(external_id: "EV9")
  end

  private

  # Regular season, so the computed slug carries no season discriminator:
  # "team-a-vs-team-b", which is what the settled matchup above names.
  def board
    {
      "events" => [{
        "id" => "EV9", "date" => 1.hour.ago.utc.iso8601,
        "season" => { "year" => 2026, "type" => 2 }, "week" => { "number" => 4 },
        "competitions" => [{
          "status" => { "period" => 4, "displayClock" => "0:00",
                        "type" => { "state" => "in", "completed" => false, "shortDetail" => "Q4" } },
          "competitors" => [
            { "id" => "1", "homeAway" => "home", "score" => "7", "team" => { "abbreviation" => "TMA" } },
            { "id" => "2", "homeAway" => "away", "score" => "0", "team" => { "abbreviation" => "TMB" } }
          ]
        }]
      }]
    }
  end

  def summary_payload
    { "scoringPlays" => [{
      "id" => "PP1", "type" => { "abbreviation" => "TD" },
      "team" => { "abbreviation" => "TMA" }, "homeScore" => 7, "awayScore" => 0,
      "period" => { "number" => 1 }, "clock" => { "displayValue" => "1:00" }, "text" => "TMA scored"
    }] }
  end

  class StubEspnClient
    def initialize(board, summary)
      @board = board
      @summary = summary
    end

    def scoreboard(**) = @board
    def summary(event_id:) = @summary
  end
end
