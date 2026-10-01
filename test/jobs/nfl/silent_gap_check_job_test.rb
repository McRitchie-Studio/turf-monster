# frozen_string_literal: true

require "test_helper"

# [integration] The tripwire ON ITS OWN CLOCK.
#
# The detection rules are covered as a unit in
# test/services/nfl/live_scores/silent_gap_check_test.rb. What is proved here is
# that a SCHEDULED tick reaches them and that its verdict tells a clean run apart
# from one that could not read the source — because the whole premise of this
# check is that silence cannot be trusted, and "no gaps found" printed after an
# ESPN outage is the same silence wearing a verdict.
class NflSilentGapCheckJobTest < ActiveSupport::TestCase
  setup do
    teams(:team_b).update!(league: "nfl", sport: "football")
  end

  test "a scheduled tick finds the gap and pages a human" do
    Game.create!(home_team_slug: teams(:team_a).slug, away_team_slug: teams(:team_b).slug,
                 season_year: 2026, season_type: 2, week: 2,
                 kickoff_at: 3.days.ago, status: "scheduled")

    assert_difference -> { ErrorLog.count }, 1 do
      Nfl::Espn::Client.stub(:new, StubEspnClient.new(final_board)) do
        Nfl::SilentGapCheckJob.perform_now
      end
    end

    assert_match "bin/nfl-live-poll --slot 2026:2:2", ErrorLog.order(:id).last.message
  end

  # THE CONTROL: with nothing suspicious in our own rows the tick is free, and
  # without this the test above passes just as well against a job that pages on
  # every run.
  test "a healthy week pages nobody and spends no request" do
    client = StubEspnClient.new(final_board)

    assert_no_difference -> { ErrorLog.count } do
      Nfl::Espn::Client.stub(:new, client) do
        Nfl::SilentGapCheckJob.perform_now
      end
    end

    assert_equal 0, client.scoreboard_calls
  end

  # A run that could not read ESPN is INCONCLUSIVE, not clean. The result says
  # so, and a caller reading `clean?` alone would be told the wrong thing.
  test "an unreadable slot comes back inconclusive rather than clean" do
    Game.create!(home_team_slug: teams(:team_a).slug, away_team_slug: teams(:team_b).slug,
                 season_year: 2026, season_type: 2, week: 2,
                 kickoff_at: 3.days.ago, status: "scheduled")

    result = Nfl::Espn::Client.stub(:new, RaisingEspnClient.new) do
      Nfl::SilentGapCheckJob.perform_now
    end

    assert result.clean?, "no gap was observed"
    refute result.conclusive?, "and nothing was actually read, which is not the same thing"
    assert_equal 0, ErrorLog.count
  end

  private

  def final_board
    {
      "events" => [{
        "id" => "EV1", "date" => 3.days.ago.utc.iso8601,
        "season" => { "year" => 2026, "type" => 2 }, "week" => { "number" => 2 },
        "competitions" => [{
          "status" => { "period" => 4, "displayClock" => "0:00",
                        "type" => { "state" => "post", "completed" => true, "shortDetail" => "Final" } },
          "competitors" => [
            { "id" => "1", "homeAway" => "home", "score" => "41", "team" => { "abbreviation" => "TMA" } },
            { "id" => "2", "homeAway" => "away", "score" => "31", "team" => { "abbreviation" => "TMB" } }
          ]
        }]
      }]
    }
  end

  class StubEspnClient
    attr_reader :scoreboard_calls

    def initialize(board)
      @board = board
      @scoreboard_calls = 0
    end

    def scoreboard(**)
      @scoreboard_calls += 1
      @board
    end
  end

  class RaisingEspnClient
    def scoreboard(**) = raise(Nfl::Espn::Client::Error, "503 from ESPN")
  end
end
