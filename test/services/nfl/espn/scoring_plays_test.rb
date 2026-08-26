require "test_helper"

# [unit] The points a scoring play is worth.
#
# This is the file that matters most in the ESPN adapter, because ESPN does NOT
# send the value of a play. It sends a label ("TD") and the score after the
# play, and the label is not enough: a touchdown is worth 6, 7, or 8 depending
# on what followed it, and ESPN folds the try into the same row.
class Nfl::Espn::ScoringPlaysTest < ActiveSupport::TestCase
  # Sampled from four real 2026 preseason games: of 33 scoring plays, 19 were
  # abbreviated "TD" and those nineteen were worth 7 (x14), 6 (x3) and 8 (x2).
  # Reading 6 off the label would have mis-scored 16 of the 19.
  test "a touchdown is worth what the score says, not what the label implies" do
    payload = {
      "scoringPlays" => [
        play(id: "1", team: "SF",  home: 0,  away: 7,  type: "TD"),  # TD + kick
        play(id: "2", team: "SF",  home: 0,  away: 13, type: "TD"),  # TD, missed kick
        play(id: "3", team: "SF",  home: 0,  away: 21, type: "TD"),  # TD + two-point
        play(id: "4", team: "LAC", home: 3,  away: 21, type: "FG")
      ]
    }

    rows = Nfl::Espn::ScoringPlays.rows_from(payload, home_abbr: "LAC", away_abbr: "SF")

    assert_equal [7, 6, 8, 3], rows.map(&:points)
    assert_equal %w[touchdown touchdown touchdown field_goal], rows.map(&:scoring_type)
  end

  # A safety credits the team that did NOT have the ball. Deciding points by
  # "whichever side moved" happens to work here, but deciding by the PLAY'S OWN
  # team is what stays correct when both sides have scored already.
  test "points follow the play's team, not whichever total moved" do
    payload = {
      "scoringPlays" => [
        play(id: "1", team: "LAC", home: 7, away: 0,  type: "TD"),
        play(id: "2", team: "SF",  home: 7, away: 2,  type: "SF")
      ]
    }

    rows = Nfl::Espn::ScoringPlays.rows_from(payload, home_abbr: "LAC", away_abbr: "SF")

    safety = rows.last
    assert_equal "SF", safety.team_abbr
    assert_equal 2, safety.points
    assert_equal "safety", safety.scoring_type
  end

  # ESPN's play id is the poller's idempotency key, so it has to survive the
  # parse as a stable string.
  test "carries the play id through as a string" do
    rows = Nfl::Espn::ScoringPlays.rows_from(
      { "scoringPlays" => [play(id: 4018732851743, team: "SF", home: 0, away: 7, type: "TD")] },
      home_abbr: "LAC", away_abbr: "SF"
    )

    assert_equal "4018732851743", rows.first.external_id
  end

  # An unrecognised abbreviation must still score. The fallback keys on what the
  # play was worth, which we always know.
  test "falls back to the point value when the abbreviation is unknown" do
    rows = Nfl::Espn::ScoringPlays.rows_from(
      { "scoringPlays" => [play(id: "1", team: "SF", home: 0, away: 3, type: "XYZ")] },
      home_abbr: "LAC", away_abbr: "SF"
    )

    assert_equal "field_goal", rows.first.scoring_type
  end

  test "skips a play crediting neither competitor rather than guessing" do
    rows = Nfl::Espn::ScoringPlays.rows_from(
      { "scoringPlays" => [play(id: "1", team: "XXX", home: 0, away: 7, type: "TD")] },
      home_abbr: "LAC", away_abbr: "SF"
    )

    assert_empty rows
  end

  test "an events-less payload parses to nothing" do
    assert_empty Nfl::Espn::ScoringPlays.rows_from({}, home_abbr: "LAC", away_abbr: "SF")
  end

  private

  def play(id:, team:, home:, away:, type:)
    {
      "id" => id,
      "type" => { "abbreviation" => type },
      "team" => { "abbreviation" => team },
      "homeScore" => home,
      "awayScore" => away,
      "period" => { "number" => 2 },
      "clock" => { "displayValue" => "5:28" },
      "text" => "#{team} scored"
    }
  end
end
