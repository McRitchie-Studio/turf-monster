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
  test "a preseason slate is invisible to the regular-season span lookup" do
    Nfl::BuildPreseasonSlate.call(year: 2026, week: 4)

    span_sources = Slate.where(week: [2, 3, 4], year: 2026, sport: "nfl")

    assert_empty span_sources.where(name: "NFL 2026 Preseason Week 4"),
      "a preseason slate must never be selectable as a regular-season span source"
  end

  test "a preseason slate stays out of the weekly ladder" do
    result = Nfl::BuildPreseasonSlate.call(year: 2026, week: 4)

    assert_nil result.slate.week
    refute_includes Slate.weekly.to_a, result.slate
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
