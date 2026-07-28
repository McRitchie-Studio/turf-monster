require "test_helper"

# The development-only demo contest a fresh worktree gets seeded with
# (db/seeds/nfl_demo_contest.rb, loaded from db/seeds.rb behind
# `Rails.env.development?`). Exercised through the seed's own entry point so the
# test covers what `bin/rails db:prepare` actually runs.
class NflDemoContestSeedTest < ActiveSupport::TestCase
  SPAN_TEAMS = %w[team-a team-b team-c team-d].freeze
  FIRST_KICKOFF = Time.utc(2026, 9, 10, 0, 20)

  # A round-robin, one week per row. Game slugs are derived from the two teams
  # ("team-a-vs-team-b"), so a pair may meet only once across the span.
  WEEK_PAIRINGS = {
    1 => [%w[team-a team-b], %w[team-c team-d]],
    2 => [%w[team-a team-c], %w[team-b team-d]],
    3 => [%w[team-a team-d], %w[team-b team-c]]
  }.freeze

  setup do
    build_weekly_nfl_slates!
    silence_warnings { load Rails.root.join("db/seeds/nfl_demo_contest.rb") }
  end

  test "seeds one open standard contest on the Weeks 1-3 span slate" do
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
    assert contest.pickable_matchups.all? { |matchup| matchup.turf_score.present? },
           "every pickable team needs the frozen multiplier the board renders and settlement pays"
    assert_equal FIRST_KICKOFF.to_i, contest.starts_at.utc.to_i,
                 "the contest opens against its first kickoff, so picks stay unlocked"
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

  test "a missing weekly slate warns rather than half-building a shorter contest" do
    Slate.find_by(name: "NFL 2026 Week 2").destroy!

    assert_raises(Nfl::BuildSpanSlate::Error) { seed_nfl_demo_contest! }
    assert_nil Contest.find_by(slug: "nfl-2026-weeks-1-3")
  end

  private

  # The three weekly NFL 2026 slates Nfl::BuildSpanSlate assembles the span
  # from — two games per week, each team playing all three weeks. Mirrors what
  # db/seeds/nfl_2026.rb + db/seeds/nfl_expected_team_totals_2026.rb produce.
  def build_weekly_nfl_slates!
    WEEK_PAIRINGS.each do |week, pairings|
      slate = Slate.create!(name: "NFL 2026 Week #{week}", slug: "nfl-2026-week-#{week}", week: week)

      pairings.each_with_index do |(home, away), index|
        game = Game.create!(
          home_team_slug: home,
          away_team_slug: away,
          kickoff_at: FIRST_KICKOFF + ((week - 1) * 7).days + index.hours,
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
