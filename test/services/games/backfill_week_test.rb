# frozen_string_literal: true

require "test_helper"

# [unit] Games::BackfillWeek — fills the null `week` on NFL rows written before
# every writer set it. Each source in its precedence order, the control row
# nothing can place, the dry run that writes nothing, and the second run that
# finds nothing to do.
class GamesBackfillWeekTest < ActiveSupport::TestCase
  # Stands in for Nfl::Espn::Client. The header shape is ESPN's live summary
  # shape, read 2026-10-24: {"week"=>7, "season"=>{"year"=>2026, "type"=>2}}.
  class StubClient
    attr_reader :calls

    def initialize(headers = {})
      @headers = headers
      @calls = []
    end

    def summary(event_id:)
      @calls << event_id
      raise Nfl::Espn::Client::Error, "ESPN /summary returned HTTP 404" unless @headers.key?(event_id)

      { "header" => @headers.fetch(event_id) }
    end
  end

  setup do
    %i[team_b team_c team_d].each { |key| teams(key).update!(league: "nfl", sport: "football") }
    # The shared fixture games are NFL here too (team_c is promoted above) and are
    # not under test: give them a week so every candidate is one this file made.
    Game.where(slug: %w[past-game future-game]).update_all(week: 1)
    @slate = Slate.create!(name: "NFL 2026 Weeks 8-10", slug: "nfl-2026-weeks-8-10", year: 2026, week: 8)
  end

  test "fills week and the null season slot from the game's slate matchups" do
    game = legacy_game!("team-a-vs-team-b")
    matchups_for!(game, week: 9)

    result = Games::BackfillWeek.call(apply: true, client: StubClient.new)

    game.reload
    assert_equal 9, game.week
    assert_equal 2026, game.season_year
    assert_equal 2, game.season_type
    assert_equal({ 9 => 1 }, result.by_week)
    assert_equal({ "matchup" => 1 }, result.by_source)
  end

  # THE CONTROL: a row no source can place stays null and is named in the report.
  test "a game with no matchup week and no ESPN id is left null and reported" do
    placed = legacy_game!("team-a-vs-team-b")
    matchups_for!(placed, week: 8)
    control = legacy_game!("team-c-vs-team-d")

    result = Games::BackfillWeek.call(apply: true, client: StubClient.new)

    assert_nil control.reload.week
    assert_equal 8, placed.reload.week
    assert_equal ["team-c-vs-team-d"], result.unresolved.map(&:slug)
    assert_match(/no matchup week and no ESPN id/, result.unresolved.first.reason)
  end

  test "matchups that name two weeks are ambiguous and never guessed" do
    game = legacy_game!("team-a-vs-team-b")
    matchups_for!(game, week: 8)
    other = Slate.create!(name: "NFL 2026 Week 10", slug: "nfl-2026-week-10", year: 2026, week: 10)
    SlateMatchup.create!(slate: other, team_slug: "team-a", opponent_team_slug: "team-b", game_slug: game.slug, week: 10)

    result = Games::BackfillWeek.call(apply: true, client: StubClient.new)

    assert_nil game.reload.week
    assert_match(/2 weeks \(8, 10\)/, result.unresolved.first.reason)
  end

  test "falls back to ESPN's event week when the row carries an ESPN id" do
    game = legacy_game!("team-a-vs-team-b", external_id: "401873010")
    client = StubClient.new("401873010" => { "week" => 7, "season" => { "year" => 2026, "type" => 2 } })

    result = Games::BackfillWeek.call(apply: true, client: client)

    assert_equal [7, 2026, 2], game.reload.slice(:week, :season_year, :season_type).values
    assert_equal({ "espn" => 1 }, result.by_source)
  end

  test "an ESPN error is reported against the row, not raised over the run" do
    game = legacy_game!("team-a-vs-team-b", external_id: "MISSING")

    result = Games::BackfillWeek.call(apply: true, client: StubClient.new)

    assert_nil game.reload.week
    assert_match(/HTTP 404/, result.unresolved.first.reason)
  end

  # A matchup week wins: ESPN is not asked about a game the matchups already place.
  test "the matchup week wins over ESPN and spends no request" do
    game = legacy_game!("team-a-vs-team-b", external_id: "401873010")
    matchups_for!(game, week: 9)
    client = StubClient.new("401873010" => { "week" => 7, "season" => { "year" => 2026, "type" => 2 } })

    Games::BackfillWeek.call(apply: true, client: client)

    assert_equal 9, game.reload.week
    assert_empty client.calls
  end

  test "a season column that already holds a value is never overwritten" do
    game = legacy_game!("team-a-vs-team-b", season_year: 2025, season_type: 3)
    matchups_for!(game, week: 9)

    Games::BackfillWeek.call(apply: true, client: StubClient.new)

    assert_equal [9, 2025, 3], game.reload.slice(:week, :season_year, :season_type).values
  end

  test "the dry run reports what it would write and writes nothing" do
    game = legacy_game!("team-a-vs-team-b")
    matchups_for!(game, week: 9)
    before = game.reload.updated_at

    result = Games::BackfillWeek.call(client: StubClient.new)

    assert_not result.apply
    assert_equal({ 9 => 1 }, result.by_week)
    game.reload
    assert_nil game.week
    assert_nil game.season_year
    assert_equal before, game.updated_at
  end

  test "a second apply finds nothing to do" do
    game = legacy_game!("team-a-vs-team-b")
    matchups_for!(game, week: 9)
    Games::BackfillWeek.call(apply: true, client: StubClient.new)

    second = Games::BackfillWeek.call(apply: true, client: StubClient.new)

    assert_equal 0, second.candidates
    assert_empty second.changes
  end

  test "a game whose week is already set is not a candidate" do
    game = Game.create!(slug: "team-a-vs-team-b", home_team_slug: "team-a", away_team_slug: "team-b", week: 4)
    matchups_for!(game, week: 9)

    result = Games::BackfillWeek.call(apply: true, client: StubClient.new)

    assert_equal 0, result.candidates
    assert_equal 4, game.reload.week
  end

  private

  # A row as production holds it: written before Game required a week.
  def legacy_game!(slug, **attrs)
    home, away = slug.split("-vs-")
    game = Game.new(slug: slug, home_team_slug: home, away_team_slug: away, **attrs)
    game.save!(validate: false)
    game
  end

  def matchups_for!(game, week:)
    [[game.home_team_slug, game.away_team_slug], [game.away_team_slug, game.home_team_slug]].each do |team, opponent|
      SlateMatchup.create!(slate: @slate, team_slug: team, opponent_team_slug: opponent, game_slug: game.slug, week: week)
    end
  end
end
