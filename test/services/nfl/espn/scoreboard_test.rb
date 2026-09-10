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

  # ── THE SITUATION ────────────────────────────────────────────────────────
  #
  # Down, distance, and who has the ball where. ESPN composes the two strings
  # for display already ("3rd & 9", "NE 13"), so the parse takes them verbatim
  # rather than re-deriving them — pluralising downs and knowing that first-and-
  # ten inside the ten is "1st & Goal" is work the feed has done.

  test "reads down, distance and field position from the situation" do
    row = Nfl::Espn::Scoreboard.rows_from(
      payload(state: "in", completed: false, situation: {
        "down" => 3, "distance" => 9, "possession" => "23",
        "downDistanceText" => "3rd & 9", "possessionText" => "NE 13"
      })
    ).first

    assert_equal "3rd & 9", row.down_distance
    assert_equal "NE 13", row.possession_text
    assert_equal "PIT", row.possession_abbr, "possession id 23 is the AWAY competitor"
  end

  # A SCHEDULED OR FINISHED GAME HAS NO SITUATION AT ALL — ESPN omits the block.
  # Reporting nil (rather than raising, or inventing an empty string) is what
  # lets the caller write the nil straight through and clear the last snap of
  # the fourth quarter off a card that now says FINAL.
  test "a game with no situation block parses to nil, not to blanks" do
    row = Nfl::Espn::Scoreboard.rows_from(payload(state: "pre", completed: false)).first

    assert_nil row.down_distance
    assert_nil row.possession_text
    assert_nil row.possession_abbr
  end

  # THE EMPTY STRING IS THE SHAPE THAT BITES. ESPN clears these fields between
  # the whistle and the next snap by sending "" rather than by dropping them,
  # and "" is a VALUE: it reaches a nullable column as a blank, renders as an
  # empty line in the rail, and reads as present to every `.present?` downstream.
  test "cleared situation fields parse to nil, not to empty strings" do
    row = Nfl::Espn::Scoreboard.rows_from(
      payload(state: "in", completed: false, situation: {
        "downDistanceText" => "", "possessionText" => "   ", "possession" => ""
      })
    ).first

    assert_nil row.down_distance
    assert_nil row.possession_text
    assert_nil row.possession_abbr
  end

  # ESPN HAS SENT THE POSSESSION ID AS BOTH A STRING AND A NUMBER across payload
  # versions, and `23 == "23"` is false in Ruby — so a numeric id would find no
  # competitor and silently drop the possession line while the rest of the
  # situation rendered fine. Compared as strings on both sides.
  test "possession resolves whether the id arrives as a string or a number" do
    as_number = Nfl::Espn::Scoreboard.rows_from(
      payload(state: "in", completed: false, situation: { "possession" => 2 })
    ).first

    assert_equal "BUF", as_number.possession_abbr
  end

  # A possession id belonging to neither competitor (a stale or malformed
  # payload) resolves to nil rather than to the wrong team. Naming the wrong
  # team is worse than naming none: the rail would colour and credit a team that
  # does not have the ball.
  test "an unknown possession id resolves to no team" do
    row = Nfl::Espn::Scoreboard.rows_from(
      payload(state: "in", completed: false, situation: { "possession" => "999", "downDistanceText" => "1st & 10" })
    ).first

    assert_nil row.possession_abbr
    assert_equal "1st & 10", row.down_distance, "the rest of the situation still parses"
  end

  def payload(state:, completed:, home: "10", away: "14", situation: :none)
    competition = {
      "status" => {
        "period" => 3, "displayClock" => "8:42",
        "type" => { "state" => state, "completed" => completed, "shortDetail" => "Q3 8:42" }
      },
      "competitors" => [
        { "id" => "2", "homeAway" => "home", "score" => home, "team" => { "abbreviation" => "BUF" } },
        { "id" => "23", "homeAway" => "away", "score" => away, "team" => { "abbreviation" => "PIT" } }
      ]
    }
    competition["situation"] = situation unless situation == :none

    {
      "events" => [{
        "id" => "401873298",
        "date" => "2026-08-27T23:00Z",
        "season" => { "year" => 2026, "type" => 1 },
        "week" => { "number" => 4 },
        "competitions" => [competition]
      }]
    }
  end
end
