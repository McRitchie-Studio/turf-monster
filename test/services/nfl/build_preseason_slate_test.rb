require "test_helper"

# [unit] The preseason TESTING slate.
class Nfl::BuildPreseasonSlateTest < ActiveSupport::TestCase
  setup do
    @home = teams(:team_a)
    @away = teams(:team_b)
    [@away, teams(:team_c), teams(:team_d)].each { |t| t.update!(league: "nfl", sport: "football") }
    @game = Game.create!(
      home_team_slug: @home.slug, away_team_slug: @away.slug,
      season_year: 2026, season_type: 1, week: 4,
      kickoff_at: 1.day.from_now, status: "scheduled"
    )
  end

  test "builds a slate, two matchups per game, and a free open contest" do
    result = Nfl::BuildPreseasonSlate.call(year: 2026, week: 4)

    assert_equal "NFL 2026 Preseason Week 4", result.slate.name
    assert_equal 1, result.games.length
    assert_equal 2, result.matchups.length
    assert_equal [@away.slug, @home.slug].sort, result.matchups.map(&:team_slug).sort
    assert_equal 0, result.contest.entry_fee_cents, "a testing slate must carry no entry fee"
    assert result.contest.open?
  end

  # THE COLLISION GUARD, and the reason `week` is nil.
  #
  # Nfl::BuildSpanSlate picks its sources with
  # `Slate.where(week:, year:, sport: "nfl")`. A preseason slate carrying week 4
  # answers that query for a regular-season "Weeks 2-4" contest and drags
  # exhibition matchups into it — silently, because the row looks like any other
  # week-4 slate.
  # THE PROPERTY IS UNCHANGED; THE MECHANISM MOVED. This used to be enforced by
  # nilling the slate's week, which also made a preseason SPAN impossible to
  # build — its own sources could not be selected either. season_type is now a
  # column and both week-based lookups scope by it, so the slate carries a real
  # week AND stays out of the regular season.
  test "a preseason slate is invisible to the regular-season span lookup" do
    Nfl::BuildPreseasonSlate.call(year: 2026, week: 4)

    sources = Nfl::BuildSpanSlate.new(year: 2026, weeks: [4]).send(:source_slates) rescue []

    refute_includes sources.map(&:name), "NFL 2026 Preseason Week 4",
      "a preseason slate must never be selectable as a regular-season span source"
  end

  # And the half the old workaround made impossible: it must now be findable BY
  # ITS OWN SEASON, or a preseason span has no sources.
  test "a preseason slate IS selectable as a preseason span source" do
    result = Nfl::BuildPreseasonSlate.call(year: 2026, week: 4)

    sources = Nfl::BuildSpanSlate.new(year: 2026, weeks: [4], season_type: Slate::PRESEASON_SEASON_TYPE)
                                 .send(:source_slates)

    assert_equal [result.slate.id], sources.map(&:id)
  end

  test "a preseason slate carries its real week number" do
    result = Nfl::BuildPreseasonSlate.call(year: 2026, week: 4)

    assert_equal 4, result.slate.week, "the week is real data, not a collision workaround"
    assert_equal Slate::PRESEASON_SEASON_TYPE, result.slate.season_type
  end

  test "the name carries the sport and year the model derives" do
    result = Nfl::BuildPreseasonSlate.call(year: 2026, week: 4)

    assert_equal "nfl", result.slate.sport
  end

  # Every matchup needs a price or the whole chain scores zero and looks broken
  # when it is only unpriced.
  test "every matchup is ranked and priced" do
    result = Nfl::BuildPreseasonSlate.call(year: 2026, week: 4)

    assert result.matchups.all? { |m| m.rank.present? }, "an unranked matchup cannot be priced"
    assert result.matchups.all? { |m| m.turf_score.present? }, "an unpriced matchup scores every entry zero"
  end

  # The builder can run mid-slate or after a rehearsal. Resetting a matchup to
  # zero would make every entry's score jump backwards on the next poll.
  test "seeds each matchup with the score the game already carries" do
    @game.goals.create!(team_slug: @home.slug, points: 6, scoring_type: "touchdown")

    result = Nfl::BuildPreseasonSlate.call(year: 2026, week: 4)

    assert_equal 6, result.matchups.find { |m| m.team_slug == @home.slug }.goals
  end

  test "rerunning creates no duplicate rows" do
    first = Nfl::BuildPreseasonSlate.call(year: 2026, week: 4)

    assert_no_difference ["Slate.count", "SlateMatchup.count", "Contest.count"] do
      second = Nfl::BuildPreseasonSlate.call(year: 2026, week: 4)
      assert_equal first.slate.id, second.slate.id
      assert_equal first.contest.id, second.contest.id
    end
  end

  test "refuses a week with no preseason games, naming the fix" do
    error = assert_raises(Nfl::BuildPreseasonSlate::Error) do
      Nfl::BuildPreseasonSlate.call(year: 2026, week: 3)
    end

    assert_match(/bin\/nfl-live-poll --slot 2026:1:3/, error.message)
  end

  # A regular-season game in the same week must not be swept in.
  test "ignores games outside the preseason slot" do
    Game.create!(home_team_slug: teams(:team_c).slug, away_team_slug: teams(:team_d).slug,
                 season_year: 2026, season_type: 2, week: 4, kickoff_at: 1.day.from_now)

    result = Nfl::BuildPreseasonSlate.call(year: 2026, week: 4)

    assert_equal 1, result.games.length
    assert_equal [@game.slug], result.games.map(&:slug)
  end
end
