# frozen_string_literal: true

require "test_helper"
require "rake"

# [unit] games:backfill_week — the post-deploy door onto Games::BackfillWeek:
# dry run unless APPLY=1, per-week counts printed, the unresolved row named.
class GamesBackfillWeekTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("games:backfill_week")
    %i[team_b team_c team_d].each { |key| teams(key).update!(league: "nfl", sport: "football") }
    # The shared fixture games are NFL here too (team_c is promoted above) and are
    # not under test: give them a week so every candidate is one this file made.
    Game.where(slug: %w[past-game future-game]).update_all(week: 1)
    slate = Slate.create!(name: "NFL 2026 Week 8", slug: "nfl-2026-week-8", year: 2026, week: 8)
    @placed = legacy_game!("team-a-vs-team-b")
    SlateMatchup.create!(slate: slate, team_slug: "team-a", opponent_team_slug: "team-b", game_slug: @placed.slug, week: 8)
    @control = legacy_game!("team-c-vs-team-d")
  end

  teardown { ENV.delete("APPLY") }

  test "dry run by default: prints per-week counts and the unresolved row, writes nothing" do
    out = run_task

    assert_match(/DRY RUN/, out)
    assert_match(/NFL games with week NULL: 2/, out)
    assert_match(/would fill: 1 \(matchup 1\)/, out)
    assert_match(/week 8: 1/, out)
    assert_match(/unresolved \(left NULL\): 1/, out)
    assert_match(/team-c-vs-team-d: no matchup week and no ESPN id/, out)
    assert_nil @placed.reload.week
  end

  test "APPLY=1 writes, and leaves the control row null" do
    ENV["APPLY"] = "1"

    out = run_task

    assert_match(/APPLY/, out)
    assert_match(/filled: 1/, out)
    assert_equal 8, @placed.reload.week
    assert_nil @control.reload.week
  end

  private

  def run_task
    task = Rake::Task["games:backfill_week"]
    task.reenable
    capture_io { task.invoke }.first
  end

  def legacy_game!(slug)
    home, away = slug.split("-vs-")
    game = Game.new(slug: slug, home_team_slug: home, away_team_slug: away)
    game.save!(validate: false)
    game
  end
end
