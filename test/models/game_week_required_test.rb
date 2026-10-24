# frozen_string_literal: true

require "test_helper"

# [unit] EVERY NFL GAME CARRIES ITS WEEK.
#
# 2026-10-24, production: 165 of 288 NFL games carried `week: NULL` because
# two of the three writers never set it, and `Game.where(week: 8)` answered 0
# for a week that existed. These pin the guard that keeps the next writer from
# repeating it, and the edges that keep the guard from bricking legacy rows.
class GameWeekRequiredTest < ActiveSupport::TestCase
  setup do
    teams(:team_b).update!(league: "nfl", sport: "football")
  end

  test "an NFL game cannot be created without a week" do
    game = Game.new(home_team_slug: teams(:team_a).slug, away_team_slug: teams(:team_b).slug)

    assert_not game.valid?
    assert_includes game.errors[:week], "can't be blank"
  end

  test "an NFL game with a week is valid" do
    game = Game.new(home_team_slug: teams(:team_a).slug, away_team_slug: teams(:team_b).slug, week: 8)

    assert game.valid?, game.errors.full_messages.to_sentence
  end

  # World Cup games share the table and have no weeks.
  test "a non-NFL game needs no week" do
    home = teams(:team_c)
    assert_not_equal "nfl", home.league
    game = Game.new(home_team_slug: home.slug, away_team_slug: teams(:team_d).slug)

    assert game.valid?, game.errors.full_messages.to_sentence
  end

  # The minutes between this deploy and the backfill: a poll that scores a
  # legacy null-week game must still save, not raise mid-cycle.
  test "a legacy null-week NFL game still takes a score update" do
    game = legacy_game!

    game.update!(home_score: 7)

    assert_equal 7, game.reload.home_score
    assert_nil game.week
  end

  test "a write that changes an NFL game's week to nil is refused" do
    game = Game.create!(home_team_slug: teams(:team_a).slug, away_team_slug: teams(:team_b).slug, week: 8)

    assert_not game.update(week: nil)
    assert_equal 8, game.reload.week
  end

  # A slot with a hole in it used to match every unstamped game of the season.
  test "in_season_slot answers none for a slot with a nil key" do
    legacy_game!(season_year: 2026, season_type: 2)

    assert_empty Game.in_season_slot(year: 2026, season_type: 2, week: nil)
    assert_empty Game.in_season_slot(year: nil, season_type: 2, week: 8)
  end

  private

  def legacy_game!(**attrs)
    game = Game.new(home_team_slug: teams(:team_a).slug, away_team_slug: teams(:team_b).slug, **attrs)
    game.save!(validate: false)
    game
  end
end
