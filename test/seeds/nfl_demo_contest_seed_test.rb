require "test_helper"

# The development-only demo contest a fresh worktree gets seeded with
# (db/seeds/nfl_demo_contest.rb, loaded from db/seeds.rb behind
# `Rails.env.development?`). Exercised through the seed's own entry point so the
# test covers what `bin/rails db:prepare` actually runs.
class NflDemoContestSeedTest < ActiveSupport::TestCase
  SPAN_TEAMS = %w[team-a team-b team-c team-d team-e team-f].freeze
  FIRST_KICKOFF = Time.utc(2026, 9, 10, 0, 20)
  SEEDED_SEASON_ID = 7

  # Five weeks of a six-team round robin. Every pair meets at most once because
  # a game's slug is derived from its two teams.
  WEEK_PAIRINGS = {
    1 => [%w[team-a team-b], %w[team-c team-f], %w[team-d team-e]],
    2 => [%w[team-a team-c], %w[team-d team-b], %w[team-e team-f]],
    3 => [%w[team-a team-d], %w[team-e team-c], %w[team-f team-b]],
    4 => [%w[team-a team-e], %w[team-f team-d], %w[team-b team-c]],
    5 => [%w[team-a team-f], %w[team-b team-e], %w[team-c team-d]]
  }.freeze

  setup do
    # Anchor "now" a week before the fixture's first kickoff. Without this the
    # suite depends on the real calendar: once it passes FIRST_KICKOFF the
    # contest seeds LOCKED, and CI runs a bare `bin/rails test`, so the red
    # would spread to every PR in the repo rather than staying in this file.
    travel_to FIRST_KICKOFF - 1.week
    SeasonConfig.set_current!(SEEDED_SEASON_ID)
    build_weekly_nfl_slates!
    silence_warnings { load Rails.root.join("db/seeds/nfl_demo_contest.rb") }
  end

  test "seeds one open standard contest on the first three upcoming weeks" do
    contest = seed_nfl_demo_contest!

    assert_equal "nfl-2026-weeks-1-3", contest.slug
    assert_equal "NFL 2026 Weeks 1-3", contest.name
    assert_equal "NFL 2026 Weeks 1-3", contest.slate.name
    assert contest.open?
    assert_equal "standard", contest.contest_type
    assert_equal Contest::FORMATS.fetch("standard").fetch(:entry_fee_cents), contest.entry_fee_cents
    assert_equal Contest::FORMATS.fetch("standard").fetch(:max_entries), contest.max_entries
  end

  test "the seeded contest is playable — three weeks, one pickable row per team, frozen multipliers" do
    contest = seed_nfl_demo_contest!

    assert contest.multi_week?
    assert_equal 3, contest.weeks_count
    assert_equal "Weeks 1-3", contest.week_span_label
    assert_equal SPAN_TEAMS.size, contest.pickable_matchups.size
    assert contest.picks_required.positive?
    assert_not contest.locked?, "a fresh worktree needs a board it can still pick on"
    assert contest.pickable_matchups.all? { |matchup| matchup.turf_score.present? },
           "every pickable team needs the frozen multiplier the board renders and settlement pays"
    assert_equal FIRST_KICKOFF.to_i, contest.starts_at.utc.to_i,
                 "the contest opens against its first kickoff, so picks stay unlocked"
  end

  test "the span rolls forward once a week has kicked off" do
    travel_to FIRST_KICKOFF + 1.day

    contest = seed_nfl_demo_contest!

    assert_equal "nfl-2026-weeks-2-4", contest.slug
    assert_equal "Weeks 2-4", contest.week_span_label
    assert_not contest.locked?, "the rolling span exists so a later worktree still gets a pickable board"
  end

  test "the span slides back rather than running off the end of the schedule" do
    # Only five weeks exist, so a season this late has no fully-future span —
    # it must stay inside the schedule instead of asking for weeks 5-7.
    travel_to kickoff_for(4) + 1.day

    contest = seed_nfl_demo_contest!

    assert_equal "nfl-2026-weeks-3-5", contest.slug
    assert_equal 3, contest.weeks_count
  end

  test "the seeded contest binds to the configured season, not season 0" do
    contest = seed_nfl_demo_contest!

    # `season_id ||= SeasonConfig.current_season_id` never re-fires, and 0 is
    # truthy — a contest seeded before the season bootstrap keeps 0 for good.
    # db/seeds.rb therefore runs this block AFTER that bootstrap.
    assert_equal SEEDED_SEASON_ID, contest.season_id
  end

  test "the seeded contest stays off chain" do
    contest = seed_nfl_demo_contest!

    assert_not contest.onchain?
    assert_nil contest.onchain_contest_id
    assert_nil contest.onchain_tx_signature
    assert contest.skip_onchain_callback, "a dev worktree has no funded devnet wallet to mint a Contest PDA with"
  end

  test "re-seeding returns the same contest instead of a duplicate" do
    first = seed_nfl_demo_contest!

    assert_no_difference -> { Contest.count } do
      assert_equal first.id, seed_nfl_demo_contest!.id
    end
  end

  test "re-seeding leaves a contest that has moved on untouched" do
    contest = seed_nfl_demo_contest!
    contest.update!(status: "settled")

    seed_nfl_demo_contest!

    assert contest.reload.settled?, "a re-seed must not re-open a contest already played locally"
  end

  test "a missing weekly slate refuses rather than half-building a shorter contest" do
    Slate.find_by(name: "NFL 2026 Week 2").destroy!

    assert_raises(Nfl::BuildSpanSlate::Error) { seed_nfl_demo_contest! }
    assert_nil Contest.find_by(slug: "nfl-2026-weeks-1-3")
  end

  test "too few weekly slates refuses with a clear message" do
    Slate.where(name: ["NFL 2026 Week 3", "NFL 2026 Week 4", "NFL 2026 Week 5"]).destroy_all

    error = assert_raises(Nfl::BuildSpanSlate::Error) { seed_nfl_demo_contest! }
    assert_match(/needs 3/, error.message)
  end

  private

  def kickoff_for(week)
    FIRST_KICKOFF + ((week - 1) * 7).days
  end

  # The weekly NFL 2026 slates Nfl::BuildSpanSlate assembles a span from —
  # mirrors what db/seeds/nfl_2026.rb + db/seeds/nfl_expected_team_totals_2026.rb
  # produce, at fixture scale.
  def build_weekly_nfl_slates!
    WEEK_PAIRINGS.each do |week, pairings|
      slate = Slate.create!(name: "NFL 2026 Week #{week}", slug: "nfl-2026-week-#{week}", week: week)

      pairings.each_with_index do |(home, away), index|
        game = Game.create!(
          home_team_slug: home,
          away_team_slug: away,
          kickoff_at: kickoff_for(week) + index.hours,
          status: "scheduled"
        )

        [[home, away], [away, home]].each do |team_slug, opponent_slug|
          SlateMatchup.create!(
            slate: slate,
            team_slug: team_slug,
            opponent_team_slug: opponent_slug,
            game_slug: game.slug,
            week: week,
            dk_goals_expectation: 24.5 - SPAN_TEAMS.index(team_slug),
            status: "pending"
          )
        end
      end
    end
  end
end
