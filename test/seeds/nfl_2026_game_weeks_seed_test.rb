# frozen_string_literal: true

require "test_helper"

# [unit] db/seeds/nfl_2026.rb writes each game's week from the schedule file.
# It used to write none, so every seeded NFL game carried `week: NULL`.
class Nfl2026GameWeeksSeedTest < ActiveSupport::TestCase
  test "every seeded game carries the week and regular-season slot of its schedule row" do
    silence_warnings { capture_io { load Rails.root.join("db/seeds/nfl_2026.rb") } }

    data = JSON.parse(File.read(Rails.root.join("db/seeds/data/nfl_2026_weeks_1_17.json")))
    games = Game.nfl.where(slug: SlateMatchup.joins(:slate).where("slates.name LIKE ?", "NFL 2026 Week %").select(:game_slug))
    assert_equal data.fetch("games").size, games.count
    assert_equal 0, games.where(week: nil).count, "no seeded NFL game may carry a null week"
    assert_equal [2026], games.distinct.pluck(:season_year)
    assert_equal [2], games.distinct.pluck(:season_type)

    # The game's week is the week of the slate the seed filed it under.
    SlateMatchup.joins(:slate).where("slates.name LIKE ?", "NFL 2026 Week %").includes(:slate, :game).find_each do |matchup|
      slate_week = matchup.slate.name[/Week (\d+)\z/, 1].to_i
      assert_equal slate_week, matchup.game.week, "#{matchup.game_slug} filed under #{matchup.slate.name}"
      assert_equal slate_week, matchup.week
    end
  end
end
