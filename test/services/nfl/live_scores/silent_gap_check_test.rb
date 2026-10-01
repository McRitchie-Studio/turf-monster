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

  # ── THE SHAPE PRODUCTION ACTUALLY HOLDS ───────────────────────────────────
  #
  # THE REGRESSION THAT BOUNCED THIS PR, and it matters more than every test
  # above it: those build their games with `season_year`/`season_type`/`week`
  # hand-stamped, and PRODUCTION DOES NOT PRODUCE THAT SHAPE until the poller
  # has already succeeded against the slot once.
  #
  # Measured on a freshly seeded database, not inferred: 272 NFL games, ZERO
  # carrying `season_year`. `PollCycle#upsert_game` is the only non-test writer
  # of those three columns; `db/seeds/nfl_2026.rb` and
  # `Nfl::CacheExpectedTeamTotals#ensure_game!` both create games without them,
  # and `AddSeasonIdentityToGames` added them with no backfill. So a prefilter
  # that REQUIRED them could only ever see a slot the poller had already polled
  # — and a slot it never polled is precisely the failure this object exists to
  # catch. The 2026 week-2 rows carried `external_id` nil and all three slot
  # columns nil, which is why a run against them reported a CONCLUSIVE CLEAN
  # week.
  #
  # The slot is resolved from the SLATE instead, which is the record named by
  # slot and the one every surface already reads: 17/17 seeded slates resolve a
  # year and a single week (the `year` column, and the week off the name through
  # `Slate#week_range`), and 256/256 seeded games reach exactly one slot that
  # way.

  test "a seed-shaped game with no slot columns is still found through its slate" do
    game = seed_shaped_game(home: teams(:team_a), away: teams(:team_b))
    assert_nil game.season_year, "the production shape: nothing has stamped a slot"
    assert_nil game.week
    assert_nil game.external_id
    client = StubClient.new(boards: { @slot_key => board(final("EV1", "TMA", "TMB", home: 41, away: 31)) })

    result = Nfl::LiveScores::SilentGapCheck.call(client: client)

    refute result.clean?, "this is the exact week-2 shape — a conclusive clean run here is the defect"
    assert result.conclusive?
    assert_equal [@slot_key], client.scoreboard_calls, "the slot came off the slate"
    assert_equal 1, result.gaps.length
    assert_equal 2026, result.gaps.first.slot.year
    assert_equal 2, result.gaps.first.slot.week
    assert_match game.slug, result.gaps.first.games.first
  end

  test "the seed-shaped gap pages a human exactly as a stamped one does" do
    seed_shaped_game(home: teams(:team_a), away: teams(:team_b))
    client = StubClient.new(boards: { @slot_key => board(final("EV1", "TMA", "TMB", home: 41, away: 31)) })

    assert_difference -> { ErrorLog.count }, 1 do
      Nfl::LiveScores::SilentGapCheck.call(client: client)
    end

    assert_match "bin/nfl-live-poll --slot 2026:2:2", ErrorLog.order(:id).last.message
  end

  # The week comes off the NAME here, because the seed writes no `week` column on
  # the slate either — measured, 0 of 17. `Slate#week_range` is the existing
  # reader for that, and this asserts the tripwire goes through it rather than
  # through a column the seed leaves null.
  test "the slot resolves from a slate carrying no week column" do
    slate = seed_shaped_slate
    assert_nil slate[:week], "the seed writes the week into the name, not the column"
    assert_equal 2026, slate[:year], "the year column IS derived, from the name, on save"
    seed_shaped_game(home: teams(:team_a), away: teams(:team_b), slate: slate)
    client = StubClient.new(boards: { @slot_key => board(final("EV1", "TMA", "TMB", home: 41, away: 31)) })

    result = Nfl::LiveScores::SilentGapCheck.call(client: client)

    assert_equal [@slot_key], client.scoreboard_calls
    refute result.clean?
  end

  # A SPAN SLATE NAMES SEVERAL WEEKS, so it cannot say which one a game sits in
  # from its name alone. Every week it covers becomes a candidate slot, and that
  # is the safe direction: the slot is only the REQUEST KEY — `unscored_final`
  # re-derives the game per scoreboard row — so an extra request can never
  # produce a false alert, while a missing one is the blindness this fixes.
  test "a game on a span slate contributes every week the span covers" do
    span = Slate.create!(name: "NFL 2026 Weeks 1-3", slug: "nfl-2026-weeks-1-3")
    seed_shaped_game(home: teams(:team_a), away: teams(:team_b), slate: span)
    client = StubClient.new(boards: { @slot_key => board(final("EV1", "TMA", "TMB", home: 41, away: 31)) })

    result = Nfl::LiveScores::SilentGapCheck.call(client: client)

    assert_equal [[2026, 2, 1], [2026, 2, 2], [2026, 2, 3]], client.scoreboard_calls.sort
    refute result.clean?, "week 2 of the span is still read, and still reports the gap"
    assert_equal 1, result.gaps.length, "only the week that actually disagreed"
  end

  # The per-matchup week wins over the span's name when it is there, which is
  # what `Nfl::BuildSpanSlate#rebuild_matchups!` writes — so an odds-CSV-built
  # span costs ONE request, not one per week.
  test "a per-matchup week pins a span slate to one request" do
    span = Slate.create!(name: "NFL 2026 Weeks 1-3", slug: "nfl-2026-weeks-1-3")
    seed_shaped_game(home: teams(:team_a), away: teams(:team_b), slate: span, matchup_week: 2)
    client = StubClient.new(boards: { @slot_key => board(final("EV1", "TMA", "TMB", home: 41, away: 31)) })

    Nfl::LiveScores::SilentGapCheck.call(client: client)

    assert_equal [@slot_key], client.scoreboard_calls
  end

  # A STAMPED GAME STILL USES ITS OWN COLUMNS, and no slate query is spent on
  # it. ESPN itself wrote that slot for that game, so it is the authoritative
  # answer and the cheapest one.
  test "a stamped game keeps resolving from its own columns" do
    unscored_game(home: teams(:team_a), away: teams(:team_b))
    SlateMatchup.create!(slate: seed_shaped_slate, team_slug: teams(:team_a).slug,
                         opponent_team_slug: teams(:team_b).slug,
                         game_slug: "team-a-vs-team-b-wrong", slug: "sm-wrong", rank: 1)
    client = StubClient.new(boards: { @slot_key => board(final("EV1", "TMA", "TMB", home: 41, away: 31)) })

    result = Nfl::LiveScores::SilentGapCheck.call(client: client)

    assert_equal [@slot_key], client.scoreboard_calls
    refute result.clean?
  end

  # A non-NFL slate must not send this check to the NFL scoreboard, and the
  # World Cup slates are exactly the rows carrying no week at all.
  test "a slate naming no week contributes no slot" do
    world_cup = Slate.create!(name: "World Cup Group A", slug: "wc-group-a")
    seed_shaped_game(home: teams(:team_a), away: teams(:team_b), slate: world_cup)
    client = StubClient.new

    result = Nfl::LiveScores::SilentGapCheck.call(client: client)

    assert result.clean?
    assert_empty client.scoreboard_calls, "there is no week to ask for"
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

  # A game NOTHING can place in a week is not a candidate — not because a null
  # slot is uninteresting, but because there is no slot to ask ESPN for. With no
  # slate naming it, no SlateMatchup points at it either, so no contest scores
  # off it and there is nothing for this check to protect.
  test "a game no slate names and no poller stamped is not a candidate" do
    Game.create!(home_team_slug: teams(:team_a).slug, away_team_slug: teams(:team_b).slug,
                 kickoff_at: 3.days.ago, status: "scheduled")
    client = StubClient.new

    result = Nfl::LiveScores::SilentGapCheck.call(client: client)

    assert result.clean?
    assert_empty client.scoreboard_calls, "there is no slot to ask about"
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

  # THE PRODUCTION SHAPE, built the way `db/seeds/nfl_2026.rb` builds it: no
  # `external_id`, no `season_year`/`season_type`/`week`, a `kickoff_at`, and a
  # slate whose NAME is the only place the week appears.
  def seed_shaped_game(home:, away:, kickoff: 3.days.ago, slate: nil, matchup_week: nil)
    game = Game.create!(
      home_team_slug: home.slug, away_team_slug: away.slug,
      kickoff_at: kickoff, status: "scheduled"
    )
    SlateMatchup.create!(
      slate: slate || seed_shaped_slate, team_slug: home.slug, opponent_team_slug: away.slug,
      game_slug: game.slug, slug: "sm-#{game.slug}", rank: 1, week: matchup_week
    )
    game
  end

  # `week` and `season_type` are left to the model: `season_type` has a NOT NULL
  # default and `year`/`sport` derive from the name in `before_validation`, which
  # is exactly what the seed relies on. The `week` COLUMN stays null, as it does
  # on all 17 seeded slates.
  def seed_shaped_slate
    @seed_shaped_slate ||= Slate.create!(name: "NFL 2026 Week 2", slug: "nfl-2026-week-2")
  end

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
