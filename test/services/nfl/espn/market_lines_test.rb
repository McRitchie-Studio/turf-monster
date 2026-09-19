require "test_helper"

# [unit] The market parse seam, read against a REAL ESPN payload
# (test/fixtures/files/espn_scoreboard_odds_week5.json — a verbatim capture of
# the odds blocks, trimmed to the keys this parses). A stub shaped from this
# parser's own assumptions would certify the parser against itself; the shapes
# that matter here — which side is favored, and what sign `spread` carries —
# are exactly the ones a hand-written stub would get wrong.
class Nfl::Espn::MarketLinesTest < ActiveSupport::TestCase
  def payload
    @payload ||= JSON.parse(file_fixture("espn_scoreboard_odds_week5.json").read)
  end

  def row_for(short_name)
    index = payload["events"].index { |event| event["shortName"] == short_name }
    Nfl::Espn::MarketLines.rows_from(payload)[index]
  end

  test "reads the week, both teams, the total and the favorite's spread" do
    row = row_for("TB @ DAL")

    assert_equal 5, row.week
    assert_equal "TB", row.away_abbr
    assert_equal "DAL", row.home_abbr
    assert_equal "DAL", row.favorite_abbr
    assert_equal(-3.5, row.favorite_spread)
    assert_equal 52.5, row.game_total
    assert row.complete?
  end

  # ESPN sends `spread` as the HOME team's line: negative when home is favored,
  # POSITIVE when the away team is. Carrying that sign through would flip the
  # favorite's spread positive on every road favorite and hand the derive
  # formula the wrong team's points.
  test "an away favorite still prices as a negative spread" do
    row = row_for("PHI VS JAX")

    assert_equal "PHI", row.favorite_abbr, "PHI is the away side and the favorite"
    assert_equal "PHI", row.away_abbr
    assert_equal(-1.5, row.favorite_spread, "the favorite's spread is negative, whichever side it is")
    assert_equal 45.5, row.game_total
  end

  test "a whole-number spread keeps its value" do
    row = row_for("CHI @ GB")

    assert_equal "GB", row.favorite_abbr
    assert_equal(-3.0, row.favorite_spread)
  end

  # --- shapes ESPN does not currently serve us -----------------------------
  # ESPN returned ONE book (DraftKings) on every 2026 game measured. These
  # cases are therefore constructed, and say so: they guard the branches that
  # would matter the day a second provider or a pick'em appears.

  def constructed(odds:, home: "DAL", away: "TB")
    {
      "events" => [{
        "week" => { "number" => 5 },
        "competitions" => [{
          "competitors" => [
            { "homeAway" => "home", "team" => { "abbreviation" => home } },
            { "homeAway" => "away", "team" => { "abbreviation" => away } }
          ],
          "odds" => odds
        }]
      }]
    }
  end

  test "DraftKings is picked out of a multi-book list, never odds[0]" do
    rows = Nfl::Espn::MarketLines.rows_from(constructed(odds: [
      { "provider" => { "name" => "ESPN BET" }, "details" => "TB -9.5", "overUnder" => 99.5, "spread" => 9.5,
        "awayTeamOdds" => { "favorite" => true } },
      { "provider" => { "name" => "DraftKings" }, "details" => "DAL -3.5", "overUnder" => 52.5, "spread" => -3.5,
        "homeTeamOdds" => { "favorite" => true } }
    ]))

    assert_equal 52.5, rows.first.game_total, "the dataset records ONE book by name"
    assert_equal "DAL", rows.first.favorite_abbr
  end

  test "a game with no DraftKings line parses incomplete rather than raising" do
    rows = Nfl::Espn::MarketLines.rows_from(constructed(odds: [
      { "provider" => { "name" => "ESPN BET" }, "details" => "DAL -3.5", "overUnder" => 52.5, "spread" => -3.5 }
    ]))

    assert_not rows.first.complete?, "the caller refuses the week; the parser stays total"
    assert_equal "TB at DAL", rows.first.matchup
  end

  test "a pick'em is a complete line at spread zero, not a gap" do
    rows = Nfl::Espn::MarketLines.rows_from(constructed(odds: [
      { "provider" => { "name" => "DraftKings" }, "details" => "EVEN", "overUnder" => 41.5 }
    ]))

    assert rows.first.complete?, "EVEN is a real line — reading it as missing would drop the game"
    assert_equal 0.0, rows.first.favorite_spread
    assert_equal "DAL", rows.first.favorite_abbr, "a pick'em nominates the home side"
  end

  test "the favorite falls back to the details string when no side is flagged" do
    rows = Nfl::Espn::MarketLines.rows_from(constructed(odds: [
      { "provider" => { "name" => "DraftKings" }, "details" => "TB -6.5", "overUnder" => 44.5, "spread" => 6.5 }
    ]))

    assert_equal "TB", rows.first.favorite_abbr
    assert_equal(-6.5, rows.first.favorite_spread)
  end

  test "a blank total reads as missing, not as zero" do
    rows = Nfl::Espn::MarketLines.rows_from(constructed(odds: [
      { "provider" => { "name" => "DraftKings" }, "details" => "DAL -3.5", "overUnder" => "", "spread" => -3.5,
        "homeTeamOdds" => { "favorite" => true } }
    ]))

    assert_nil rows.first.game_total, "0.0 would be ingested as a real game total"
    assert_not rows.first.complete?
  end

  test "an empty payload parses to nothing" do
    assert_empty Nfl::Espn::MarketLines.rows_from({})
    assert_empty Nfl::Espn::MarketLines.rows_from({ "events" => [] })
  end
end
