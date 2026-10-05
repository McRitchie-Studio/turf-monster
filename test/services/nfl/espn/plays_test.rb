require "test_helper"

# [unit] The play-by-play parse seam, over payloads ESPN actually served:
# DET at CAR, 2026-10-04, captured in the fourth quarter. The summary fixture
# keeps the first two drives and the last four (64 plays); the scoreboard
# fixture is the same instant's situation block for that one game.
class Nfl::Espn::PlaysTest < ActiveSupport::TestCase
  def summary    = JSON.parse(file_fixture("espn_summary_live_plays.json").read)
  def scoreboard = JSON.parse(file_fixture("espn_scoreboard_live_plays.json").read)
  def rows       = Nfl::Espn::Plays.rows_from(summary)

  test "reads every play of the summary once, oldest first" do
    assert_equal 64, rows.length
    assert_equal rows.map(&:external_id).uniq, rows.map(&:external_id)
    assert_equal "40187297839", rows.first.external_id
    assert_equal "4018729784422", rows.last.external_id
  end

  # drives.current repeats the last entry of drives.previous while the drive is
  # still going. Counted twice, every play of the live drive would be stored
  # under one id and then fought over.
  test "the live drive is not counted twice" do
    payload = summary
    assert_equal payload.dig("drives", "previous").last["id"], payload.dig("drives", "current", "id")

    in_previous = payload.dig("drives", "previous").sum { |drive| drive["plays"].length }
    assert_equal in_previous, rows.length
  end

  test "a play carries its quarter, clock, down, yardage and running score" do
    play = rows.last

    assert_equal "Pass Reception", play.play_type
    assert_equal "play", play.kind
    assert_equal 4, play.period
    assert_equal "4:05", play.clock
    assert_equal "4th & 5 at CAR 10", play.down_distance
    assert_equal 7, play.yards
    assert_equal [32, 19], [play.home_score, play.away_score]
    assert_equal "DET", play.team_abbr
    assert_equal "(Shotgun) J.Goff pass short right to S.LaPorta to CAR 3 for 7 yards (D.Lloyd; Z.Wheatley).", play.text
  end

  # The one a reader is counting. An official timeout costs nobody anything and
  # must not be dressed as a team's.
  test "a team timeout is a timeout; an official one is a break" do
    by_type = rows.group_by(&:play_type)

    assert_equal %w[timeout], by_type.fetch("Timeout").map(&:kind).uniq
    assert_equal %w[break], by_type.fetch("Official Timeout").map(&:kind).uniq
    assert_equal "Timeout #1 by DET at 12:09.", by_type.fetch("Timeout").first.text
  end

  test "names the kinds the board marks" do
    kinds = rows.to_h { |row| [row.play_type, row.kind] }

    assert_equal "penalty", kinds.fetch("Penalty")
    assert_equal "score",   kinds.fetch("Field Goal Good")
    assert_equal "sack",    kinds.fetch("Sack")
    assert_equal "kick",    kinds.fetch("Punt")
    assert_equal "kick",    kinds.fetch("Kickoff")
    assert_equal "play",    kinds.fetch("Rush")
    assert_empty rows.map(&:kind) - Nfl::Espn::Plays::KINDS
  end

  # ESPN types a fumble returned for a touchdown by the fumble. Only the flag
  # says it scored, and only the flag says a strip-sack changed possession.
  test "the feed's flags outrank the wording of the type" do
    fumble_six = { "id" => "9", "type" => { "text" => "Fumble Return" }, "text" => "x", "scoringPlay" => true }
    strip_sack = { "id" => "8", "type" => { "text" => "Sack" }, "text" => "x", "isTurnover" => true }
    pick       = { "id" => "7", "type" => { "text" => "Pass Interception Return" }, "text" => "x" }
    warning    = { "id" => "6", "type" => { "text" => "Two-minute warning" }, "text" => "x", "scoringPlay" => true }
    unknown    = { "id" => "5", "type" => { "text" => "Something New In 2027" }, "text" => "x" }

    assert_equal "score",    Nfl::Espn::Plays.row_from(fumble_six).kind
    assert_equal "turnover", Nfl::Espn::Plays.row_from(strip_sack).kind
    assert_equal "turnover", Nfl::Espn::Plays.row_from(pick).kind
    assert_equal "break",    Nfl::Espn::Plays.row_from(warning).kind
    assert_equal "play",     Nfl::Espn::Plays.row_from(unknown).kind
  end

  # ── first downs ──────────────────────────────────────────────────────────

  # 4th & 5 at the CAR 10, a 7-yard catch, 1st & Goal: the chains moved.
  test "a snap that makes the distance and keeps the ball is a first down" do
    assert rows.last.first_down
    assert_equal 14, rows.count(&:first_down)
    assert_equal %w[play], rows.select(&:first_down).map(&:kind).uniq
  end

  test "a first down is an ordinary snap that kept the ball, and nothing else" do
    snap = lambda do |overrides|
      { "id" => "1", "type" => { "text" => "Rush" }, "text" => "x", "statYardage" => 12,
        "start" => { "down" => 2, "distance" => 8, "team" => { "id" => "8" } },
        "end" => { "down" => 1, "distance" => 10, "team" => { "id" => "8" } } }.deep_merge(overrides)
    end
    first_down = ->(overrides = {}) { Nfl::Espn::Plays.row_from(snap.(overrides)).first_down }

    assert first_down.()
    assert_not first_down.("statYardage" => 5), "short of the sticks"
    assert_not first_down.("end" => { "team" => { "id" => "29" } }), "the other side has it: a turnover or a kick"
    assert_not first_down.("start" => { "down" => 0 }), "a kickoff has no down to convert"
    assert_not first_down.("type" => { "text" => "Penalty" }), "a flag that hands over a first down moved nobody"
    assert_not first_down.("type" => { "text" => "Rushing Touchdown" }), "a touchdown is a score"
  end

  # "Cannot say" must never read as "did not" — the scoreboard's copy would
  # otherwise erase a first down the summary had already recorded.
  test "a play with no before-and-after says nothing about a first down" do
    assert_nil Nfl::Espn::Plays.row_from({ "id" => "1", "type" => { "text" => "Rush" }, "text" => "x" }).first_down
  end

  # The scoreboard's copy has no down of its own, so it reads the situation the
  # play left behind: same team, first down, ground gained.
  test "the scoreboard infers a first down from the situation the play left" do
    row = Nfl::Espn::Scoreboard.rows_from(scoreboard).first
    assert row.last_play.first_down, "1st & Goal for DET after a 7-yard DET catch"

    second_down = scoreboard
    second_down["events"].first["competitions"].first["situation"]["down"] = 2
    assert_not Nfl::Espn::Scoreboard.rows_from(second_down).first.last_play.first_down

    changed_hands = scoreboard
    changed_hands["events"].first["competitions"].first["situation"]["possession"] = "29"
    assert_not Nfl::Espn::Scoreboard.rows_from(changed_hands).first.last_play.first_down
  end

  test "a play with no id, or with nothing to say, is skipped" do
    assert_nil Nfl::Espn::Plays.row_from({ "id" => " ", "text" => "x" })
    assert_nil Nfl::Espn::Plays.row_from({ "id" => "1", "text" => "", "type" => {} })
  end

  # A degraded 200 with no drives block is the feed declining to answer.
  test "a summary with no drives block is not a report of zero plays" do
    assert_not Nfl::Espn::Plays.reported?({ "scoringPlays" => [] })
    assert_not Nfl::Espn::Plays.reported?(nil)
    assert Nfl::Espn::Plays.reported?({ "drives" => {} })
    assert_equal [], Nfl::Espn::Plays.rows_from({ "scoringPlays" => [] })
  end

  # ── the scoreboard's half ────────────────────────────────────────────────

  test "the scoreboard row carries the last play and each side's timeouts" do
    row = Nfl::Espn::Scoreboard.rows_from(scoreboard).first

    assert_equal "4018729784422", row.last_play.external_id
    assert_equal "DET", row.last_play.team_abbr
    assert_equal "play", row.last_play.kind
    # The scoreboard stamps no clock on the play; the game's own stands in.
    assert_equal [4, "3:42"], [row.last_play.period, row.last_play.clock]
    assert_nil row.last_play.down_distance
    assert_equal [1, 3], [row.home_timeouts, row.away_timeouts]
  end

  test "the same play has the same id on both feeds" do
    assert_equal rows.last.external_id, Nfl::Espn::Scoreboard.rows_from(scoreboard).first.last_play.external_id
  end

  test "a game with no situation has no last play and no timeout count" do
    payload = scoreboard
    payload["events"].first["competitions"].first.delete("situation")
    row = Nfl::Espn::Scoreboard.rows_from(payload).first

    assert_nil row.last_play
    assert_nil row.home_timeouts
    assert_nil row.away_timeouts
  end

  test "a scoreboard row built without the new fields still stands" do
    row = Nfl::Espn::Scoreboard::Row.new(
      external_id: "1", season_year: 2026, season_type: 2, week: 4, kickoff_at: nil, status: "scheduled",
      home_abbr: "A", home_score: nil, away_abbr: "B", away_score: nil, period: nil, clock: nil, detail: nil,
      down_distance: nil, possession_text: nil, possession_abbr: nil
    )

    assert_nil row.last_play
  end
end
