# frozen_string_literal: true

require "test_helper"

# [unit] WHICH ESPN SLOT A GAME WE HOLD BELONGS TO.
#
# This object exists because of a measured blind spot, not a hypothetical one.
# `SilentGapCheck` used to find its candidate slots by requiring
# `games.season_year`, `season_type` and `week` to be non-null, and
# `Nfl::LiveScores::PollCycle#upsert_game` is the ONLY non-test writer of those
# three columns. So the tripwire could see a slot only AFTER the poller had
# already succeeded against it — and a slot the poller never reached is exactly
# the failure it exists to catch. Pointed at a rebuild of the 2026 week-2 rows it
# reported a CONCLUSIVE CLEAN WEEK.
#
# Measured on a freshly seeded database: 272 NFL games, ZERO carrying
# season_year; 256 carrying kickoff_at; 18 slates, all 18 resolving a year and
# exactly one week; 256/256 games reaching exactly one slot through their slate.
#
# Each test below pins ONE link of the precedence chain, at the lowest tier,
# because a chain tested only through its caller is a chain whose middle links
# can rot unnoticed.
class NflSlotResolverTest < ActiveSupport::TestCase
  setup do
    [teams(:team_b), teams(:team_c)].each { |t| t.update!(league: "nfl", sport: "football") }
  end

  # ── THE GAME'S OWN COLUMNS WIN ────────────────────────────────────────────

  # ESPN wrote those columns for that game, so they are the authoritative answer
  # and the free one — no slate is read at all.
  test "a fully stamped game resolves from its own columns and ignores its slate" do
    game = game_on(slate_named("NFL 2026 Week 9"), season_year: 2026, season_type: 2, week: 4)

    assert_equal [slot(2026, 2, 4)], Nfl::LiveScores::SlotResolver.call([game])
  end

  # ALL THREE, NOT ANY. A half-stamped row names no slot ESPN can serve — asking
  # for "week nil" is not a request worth making — so it must fall through to the
  # slate rather than produce a slot with a hole in it.
  test "a half-stamped game falls through to its slate" do
    game = game_on(slate_named("NFL 2026 Week 5"), season_year: 2026, season_type: 2, week: nil)

    assert_equal [slot(2026, 2, 5)], Nfl::LiveScores::SlotResolver.call([game])
  end

  # ── THE SLATE ANSWERS, THROUGH THREE SOURCES IN ORDER ─────────────────────

  # THE SEED'S SHAPE, and the one that matters: db/seeds/nfl_2026.rb writes the
  # week into the slate's NAME and into no column anywhere — 0 of 17 slates and
  # 0 of 512 matchups carry one. `Slate#week_range` is the existing reader for it.
  test "the week comes off the slate name when no column carries it" do
    slate = slate_named("NFL 2026 Week 2")
    assert_nil slate[:week]
    assert_nil SlateMatchup.new.week
    game = game_on(slate)

    assert_equal [slot(2026, 2, 2)], Nfl::LiveScores::SlotResolver.call([game])
  end

  # The odds-CSV slate build (Nfl::CacheExpectedTeamTotals#ensure_slate!) writes
  # the column, so it is preferred over re-parsing the name.
  test "the slate week column beats the name" do
    slate = slate_named("NFL 2026 Week 2")
    slate.update!(week: 7)
    game = game_on(slate)

    assert_equal [slot(2026, 2, 7)], Nfl::LiveScores::SlotResolver.call([game])
  end

  # THE ONLY SOURCE THAT CAN SPEAK FOR A SPAN. A "Weeks 1-3" slate holds three
  # weeks of games, so only the per-matchup week — which
  # Nfl::BuildSpanSlate#rebuild_matchups! writes — says which one a game is in.
  test "the matchup week beats both, which is what pins a span slate" do
    game = game_on(slate_named("NFL 2026 Weeks 1-3"), matchup_week: 3)

    assert_equal [slot(2026, 2, 3)], Nfl::LiveScores::SlotResolver.call([game])
  end

  # A span whose matchups carry no week cannot say which of its weeks the game is
  # in, so it offers all of them. That is the SAFE direction, not a shrug: the
  # slot is only a REQUEST KEY, and SilentGapCheck#unscored_final re-derives the
  # game from each scoreboard row it gets back. An extra slot costs one request;
  # a missing one is total blindness.
  test "a span slate with no matchup week contributes every week it names" do
    game = game_on(slate_named("NFL 2026 Weeks 1-3"))

    assert_equal [slot(2026, 2, 1), slot(2026, 2, 2), slot(2026, 2, 3)],
                 Nfl::LiveScores::SlotResolver.call([game]).sort_by(&:week)
  end

  # PRESEASON WEEK 3 AND REGULAR WEEK 3 BOTH EXIST, so the season type has to ride
  # along or a slot means two different weekends. Slate derives it from the name.
  test "the season type rides with the week" do
    slate = slate_named("NFL 2026 Preseason Week 3")
    assert_equal Slate::PRESEASON_SEASON_TYPE, slate.season_type
    game = game_on(slate)

    assert_equal [slot(2026, 1, 3)], Nfl::LiveScores::SlotResolver.call([game])
  end

  # ── WHAT NAMES NO SLOT AT ALL ─────────────────────────────────────────────

  # No slate names it and no poller stamped it, so nothing can place it in a week
  # — and no SlateMatchup points at it either, so no contest scores off it.
  test "a game on no slate resolves to nothing" do
    game = Game.create!(home_team_slug: teams(:team_a).slug, away_team_slug: teams(:team_b).slug)

    assert_empty Nfl::LiveScores::SlotResolver.call([game])
  end

  # Every World Cup slate is this shape. There is no week to ask ESPN for.
  #
  # The name carries a YEAR deliberately, so only the week guard can be what
  # fires: a year-less name would also be refused by the guard below, and a test
  # that cannot say which of two guards answered it proves neither.
  test "a slate naming no week resolves to nothing" do
    slate = slate_named("World Cup 2026 Group A")
    assert_equal "2026", slate.season_year, "the year resolves; only the week is missing"
    game = game_on(slate)

    assert_empty Nfl::LiveScores::SlotResolver.call([game])
  end

  # A slot is a (year, season_type, week) triple and ESPN serves it by year. A
  # slate with no year in its column and none in its name cannot complete one.
  test "a slate with no year resolves to nothing" do
    slate = slate_named("NFL Week 2")
    assert_nil slate.season_year, "neither the column nor the name carries a year"
    game = game_on(slate)

    assert_empty Nfl::LiveScores::SlotResolver.call([game])
  end

  test "no games resolve to no slots" do
    assert_empty Nfl::LiveScores::SlotResolver.call([])
  end

  # ── COST ──────────────────────────────────────────────────────────────────

  # The seed writes TWO matchups per game — one per team — and a whole broken week
  # is 16 games on one slate. Without the de-duplication that is 32 identical
  # scoreboard requests for one week, every six hours.
  test "two matchups on one game, and two games on one slate, name the slot once" do
    slate = slate_named("NFL 2026 Week 2")
    first = game_on(slate, both_sides: true)
    second = game_on(slate, home: teams(:team_c), away: teams(:team_d), both_sides: true)
    assert_equal 4, SlateMatchup.where(game_slug: [first.slug, second.slug]).count

    assert_equal [slot(2026, 2, 2)], Nfl::LiveScores::SlotResolver.call([first, second])
  end

  private

  def slot(year, season_type, week)
    Nfl::LiveScores::PollCycle::Slot.new(year: year, season_type: season_type, week: week)
  end

  # `week`/`year`/`season_type` are left to the model exactly as the seed leaves
  # them: season_type has a NOT NULL default and sport/year derive from the name
  # in Slate's before_validation. The `week` COLUMN stays null.
  def slate_named(name)
    Slate.create!(name: name, slug: name.parameterize)
  end

  def game_on(slate, home: nil, away: nil, season_year: nil, season_type: nil, week: nil,
              matchup_week: nil, both_sides: false)
    home ||= teams(:team_a)
    away ||= teams(:team_b)
    game = Game.create!(home_team_slug: home.slug, away_team_slug: away.slug,
                        season_year: season_year, season_type: season_type, week: week)
    sides = both_sides ? [[home, away], [away, home]] : [[home, away]]
    sides.each do |team, opponent|
      SlateMatchup.create!(slate: slate, team_slug: team.slug, opponent_team_slug: opponent.slug,
                           game_slug: game.slug, slug: "sm-#{game.slug}-#{team.slug}",
                           week: matchup_week)
    end
    game
  end
end
