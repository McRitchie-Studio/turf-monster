require "test_helper"

# [unit] The scoreboard parse seam.
class Nfl::Espn::ScoreboardTest < ActiveSupport::TestCase
  test "reads the season slot, teams, scores and clock from an event" do
    row = Nfl::Espn::Scoreboard.rows_from(payload(state: "in", completed: false)).first

    assert_equal "401873298", row.external_id
    assert_equal 2026, row.season_year
    assert_equal 1, row.season_type
    assert_equal 4, row.week
    assert_equal "in_progress", row.status
    assert_equal "BUF", row.home_abbr
    assert_equal 10, row.home_score
    assert_equal "PIT", row.away_abbr
    assert_equal 14, row.away_score
    assert_equal 3, row.period
    assert_equal "8:42", row.clock
  end

  # A POSTPONED game is also state "post". Only the `completed` flag separates
  # it from a finished one, and treating it as final would settle contests on a
  # game nobody played.
  test "a postponed game is not completed just because its state is post" do
    postponed = Nfl::Espn::Scoreboard.rows_from(payload(state: "post", completed: false)).first
    finished  = Nfl::Espn::Scoreboard.rows_from(payload(state: "post", completed: true)).first

    assert_equal "scheduled", postponed.status
    assert_equal "completed", finished.status
  end

  # A BLANK SCORE READS AS nil, NOT ZERO — and this test changed deliberately.
  #
  # It used to assert 0, which is the collapse that let a corrupted board look
  # healthy: a degraded response wiped a game's goals to 0-0, and because the
  # blank scoreboard score ALSO parsed to 0, the drift check compared two zeros,
  # agreed, and emitted no anomaly. "No score yet" and "a score of zero" are
  # different facts and the parse seam now reports them differently.
  #
  # Which one a blank MEANS depends on the game's status, which this seam does
  # not have — so it reports honestly and PollCycle#scores_known? decides.
  test "a blank score reads as nil — unknown, not zero" do
    row = Nfl::Espn::Scoreboard.rows_from(payload(state: "pre", completed: false, home: "", away: "")).first

    assert_equal "scheduled", row.status
    assert_nil row.home_score
    assert_nil row.away_score
  end

  test "a real zero is still a zero" do
    row = Nfl::Espn::Scoreboard.rows_from(payload(state: "in", completed: false, home: "0", away: "0")).first

    assert_equal 0, row.home_score
    assert_equal 0, row.away_score
  end

  test "skips an event missing a competitor instead of raising" do
    broken = { "events" => [{ "id" => "1", "competitions" => [{ "competitors" => [] }] }] }

    assert_empty Nfl::Espn::Scoreboard.rows_from(broken)
  end

  test "an events-less payload parses to nothing" do
    assert_empty Nfl::Espn::Scoreboard.rows_from({})
    assert_empty Nfl::Espn::Scoreboard.rows_from({ "events" => nil })
  end

  private

  def payload(state:, completed:, home: "10", away: "14")
    {
      "events" => [{
        "id" => "401873298",
        "date" => "2026-08-27T23:00Z",
        "season" => { "year" => 2026, "type" => 1 },
        "week" => { "number" => 4 },
        "competitions" => [{
          "status" => {
            "period" => 3, "displayClock" => "8:42",
            "type" => { "state" => state, "completed" => completed, "shortDetail" => "Q3 8:42" }
          },
          "competitors" => [
            { "homeAway" => "home", "score" => home, "team" => { "abbreviation" => "BUF" } },
            { "homeAway" => "away", "score" => away, "team" => { "abbreviation" => "PIT" } }
          ]
        }]
      }]
    }
  end
end
