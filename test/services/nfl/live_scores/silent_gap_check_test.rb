# frozen_string_literal: true

require "test_helper"

# [unit] THE TRIPWIRE FOR THE WEEK THAT VANISHED.
#
# Regular season 2026 week 2, measured on turf-monster-mainnet 2026-09-27: ESPN
# reported all 16 games Final; we held all 16 at `status=scheduled` with ZERO
# goals. An entire week of NFL scoring was never ingested, and the Weeks 1-3
# contest — 7 active PAID entries — scored on two weeks out of three for ten
# days. The backfill moved the contest total 1548.9 -> 2930.3 and CHANGED THE
# LEADERBOARD ORDER.
#
# WHAT MAKES THAT CLASS OF FAILURE SPECIAL, and why a scheduled job alone is not
# the fix: there was no error, no anomaly, no `degraded_feed`, nothing in an
# ErrorLog. The standings simply omitted a week and looked entirely plausible —
# 1548.9 points is not obviously wrong. Nothing in the system would ever have
# surfaced it; a customer would have. A scheduled poll closes the common case,
# and a cron that dies, is never loaded, or loses its `active_job: true` flag
# fails exactly as silently as no cron at all. So the tripwire is the half that
# has to hold when the schedule itself fails.
#
# THE PREDICATE, stated once: a slot whose games are FINAL at the source but
# carry ZERO scoring events here. That is the whole class, and it is checked
# against ESPN rather than against a clock, because a postponed game is
# legitimately unfinished and a legitimately 0-0 game is legitimately unscored.
class NflSilentGapCheckTest < ActiveSupport::TestCase
  # Stands in for Nfl::Espn::Client, and COUNTS its calls. The count is a real
  # assertion, not bookkeeping: the check runs on a cron against every recent
  # slot, so a clean week must cost ZERO network requests. The DB prefilter is
  # what makes that true, and only a call count can prove it.
  class StubClient
    attr_reader :scoreboard_calls

    def initialize(boards: {}, raise_for: [])
      @boards = boards
      @raise_for = raise_for
      @scoreboard_calls = []
    end

    def scoreboard(year: nil, season_type: nil, week: nil)
      key = [year, season_type, week]
      @scoreboard_calls << key
      raise Nfl::Espn::Client::Error, "scoreboard unavailable" if @raise_for.include?(key)

      @boards.fetch(key, { "events" => [] })
    end
  end

  setup do
    # Only team_a carries league: nfl in the shared fixtures, and TeamMap looks
    # inside Team.nfl on purpose. Enrolling the others inside the test
    # transaction is cheaper than widening a fixture every other suite reads.
    [teams(:team_b), teams(:team_c), teams(:team_d)].each do |team|
      team.update!(league: "nfl", sport: "football")
    end
    @slot_key = [2026, 2, 2]
  end

  # ── THE REGRESSION ────────────────────────────────────────────────────────

  test "a slot whose games are final at the source but hold zero goals is detected" do
    game = unscored_game(home: teams(:team_a), away: teams(:team_b))
    client = StubClient.new(boards: { @slot_key => board(final("EV1", "TMA", "TMB", home: 41, away: 31)) })

    result = Nfl::LiveScores::SilentGapCheck.call(client: client)

    refute result.clean?, "ESPN said FINAL 31-41 and we hold zero goals — that is the week-2 shape"
    assert_equal 1, result.gaps.length
    gap = result.gaps.first
    assert_equal 2026, gap.slot.year
    assert_equal 2, gap.slot.season_type
    assert_equal 2, gap.slot.week
    assert_equal 1, gap.games.length
    assert_match game.slug, gap.games.first
  end

  test "the gap raises an ErrorLog naming the slot and the exact repair command" do
    unscored_game(home: teams(:team_a), away: teams(:team_b))
    client = StubClient.new(boards: { @slot_key => board(final("EV1", "TMA", "TMB", home: 41, away: 31)) })

    assert_difference -> { ErrorLog.count }, 1 do
      Nfl::LiveScores::SilentGapCheck.call(client: client)
    end

    log = ErrorLog.order(:id).last
    assert_match "2026 Regular week 2", log.message
    assert_match "bin/nfl-live-poll --slot 2026:2:2", log.message,
                 "an alert a human cannot act on is barely an alert"
    assert_match(/zero scoring events/i, log.message)
  end

  # Every game in the slot, not just the first one: the incident was 16 of 16,
  # and an alert that named one of them would understate it by a whole week.
  test "every unscored final in the slot is named in one alert" do
    unscored_game(home: teams(:team_a), away: teams(:team_b))
    unscored_game(home: teams(:team_c), away: teams(:team_d))
    client = StubClient.new(boards: { @slot_key => board(
      final("EV1", "TMA", "TMB", home: 41, away: 31),
      final("EV2", "TMC", "TMD", home: 3, away: 34)
    ) })

    result = Nfl::LiveScores::SilentGapCheck.call(client: client)

    assert_equal 1, result.gaps.length, "one slot, one alert"
    assert_equal 2, result.gaps.first.games.length
    assert_equal 1, ErrorLog.count
  end

  # ── WHAT IT MUST NOT FLAG ─────────────────────────────────────────────────

  # THE COST ASSERTION. A week we have already scored must not reach the network
  # at all, because this runs on a cron over every recent slot. The DB prefilter
  # is the whole reason a clean check is free.
  test "a slot we have already scored is clean and costs zero ESPN requests" do
    game = unscored_game(home: teams(:team_a), away: teams(:team_b), status: "completed")
    game.goals.create!(team_slug: teams(:team_a).slug, points: 7, scoring_type: "touchdown",
                       external_id: "P1")
    client = StubClient.new(boards: { @slot_key => board(final("EV1", "TMA", "TMB", home: 7, away: 0)) })

    result = Nfl::LiveScores::SilentGapCheck.call(client: client)

    assert result.clean?
    assert_empty client.scoreboard_calls,
                 "a scored week must not spend a request — the DB prefilter answers first"
  end

  # A 0-0 final has not happened in the NFL since 1943, but it is not impossible,
  # and it is indistinguishable from the incident on a goal count alone. The
  # FEED'S OWN TOTAL is what separates them.
  test "a legitimately scoreless final is not a gap" do
    unscored_game(home: teams(:team_a), away: teams(:team_b))
    client = StubClient.new(boards: { @slot_key => board(final("EV1", "TMA", "TMB", home: 0, away: 0)) })

    result = Nfl::LiveScores::SilentGapCheck.call(client: client)

    assert result.clean?, "0-0 at the source and zero goals here AGREE"
  end

  # A postponed game is also ESPN state "post"; only `completed` tells them
  # apart, and treating one as final would page a human about a game nobody
  # played. Nfl::Espn::Scoreboard already draws that line — this asserts the
  # check honours it.
  test "a postponed game is not a finished one" do
    unscored_game(home: teams(:team_a), away: teams(:team_b))
    client = StubClient.new(boards: { @slot_key => board(
      event("EV1", "TMA", "TMB", home: nil, away: nil, state: "post", completed: false)
    ) })

    result = Nfl::LiveScores::SilentGapCheck.call(client: client)

    assert result.clean?
  end

  test "a game still being played is not a gap" do
    unscored_game(home: teams(:team_a), away: teams(:team_b), status: "in_progress")
    client = StubClient.new(boards: { @slot_key => board(
      event("EV1", "TMA", "TMB", home: 7, away: 3, state: "in", completed: false)
    ) })

    result = Nfl::LiveScores::SilentGapCheck.call(client: client)

    assert result.clean?
  end

  # The grace window is what keeps the check off a slate that is still being
  # played. A game an hour past kickoff is mid-game, not missing.
  test "a game inside the grace window is not yet suspicious" do
    unscored_game(home: teams(:team_a), away: teams(:team_b), kickoff: 1.hour.ago)
    client = StubClient.new(boards: { @slot_key => board(final("EV1", "TMA", "TMB", home: 41, away: 31)) })

    result = Nfl::LiveScores::SilentGapCheck.call(client: client)

    assert result.clean?
    assert_empty client.scoreboard_calls
  end

  test "a slot older than the lookback is left alone" do
    unscored_game(home: teams(:team_a), away: teams(:team_b),
                  kickoff: Nfl::LiveScores::SilentGapCheck::LOOKBACK.ago - 1.day)
    client = StubClient.new(boards: { @slot_key => board(final("EV1", "TMA", "TMB", home: 41, away: 31)) })

    result = Nfl::LiveScores::SilentGapCheck.call(client: client)

    assert result.clean?
    assert_empty client.scoreboard_calls
  end

  # A game with no season slot cannot be rendered as a week, and every game
  # predating the live feed has one. Asking ESPN for "week nil" is not a request
  # worth making.
  test "a game carrying no season slot is not a candidate" do
    Game.create!(home_team_slug: teams(:team_a).slug, away_team_slug: teams(:team_b).slug,
                 kickoff_at: 3.days.ago, status: "scheduled")
    client = StubClient.new

    result = Nfl::LiveScores::SilentGapCheck.call(client: client)

    assert result.clean?
    assert_empty client.scoreboard_calls
  end

  # Game is shared with the World Cup contests. A soccer fixture carrying a
  # season slot must not send this check to the NFL scoreboard.
  test "a non-NFL game is not a candidate" do
    soccer = teams(:team_e)
    soccer.update!(league: "world_cup", sport: "soccer")
    Game.create!(home_team_slug: soccer.slug, away_team_slug: teams(:team_f).slug,
                 season_year: 2026, season_type: 2, week: 2,
                 kickoff_at: 3.days.ago, status: "scheduled")
    client = StubClient.new

    result = Nfl::LiveScores::SilentGapCheck.call(client: client)

    assert result.clean?
    assert_empty client.scoreboard_calls
  end

  # ── A CHECK THAT COULD NOT RUN IS NOT A CLEAN CHECK ───────────────────────

  # The whole point of this object is that silence is untrustworthy. So a slot
  # whose scoreboard did not arrive is REPORTED as unreadable rather than
  # counted as agreement — otherwise an ESPN outage reads as "no gaps".
  test "a slot whose scoreboard did not arrive is reported unreadable, not clean" do
    unscored_game(home: teams(:team_a), away: teams(:team_b))
    client = StubClient.new(raise_for: [@slot_key])

    result = Nfl::LiveScores::SilentGapCheck.call(client: client)

    assert result.clean?, "we did not observe a gap"
    assert_equal 1, result.unreadable.length
    refute result.conclusive?, "a check that could not read the source proves nothing"
  end

  private

  def unscored_game(home:, away:, kickoff: 3.days.ago, status: "scheduled", week: 2)
    Game.create!(
      home_team_slug: home.slug, away_team_slug: away.slug,
      season_year: 2026, season_type: 2, week: week,
      kickoff_at: kickoff, status: status
    )
  end

  def board(*events) = { "events" => events }

  def final(id, home_abbr, away_abbr, home:, away:)
    event(id, home_abbr, away_abbr, home: home, away: away, state: "post", completed: true)
  end

  def event(id, home_abbr, away_abbr, home:, away:, state:, completed:)
    {
      "id" => id,
      "date" => 3.days.ago.utc.iso8601,
      "season" => { "year" => 2026, "type" => 2 },
      "week" => { "number" => 2 },
      "competitions" => [{
        "status" => { "period" => 4, "displayClock" => "0:00",
                      "type" => { "state" => state, "completed" => completed,
                                  "shortDetail" => completed ? "Final" : "Postponed" } },
        "competitors" => [
          { "id" => "1", "homeAway" => "home", "score" => home&.to_s,
            "team" => { "abbreviation" => home_abbr } },
          { "id" => "2", "homeAway" => "away", "score" => away&.to_s,
            "team" => { "abbreviation" => away_abbr } }
        ]
      }]
    }
  end
end
