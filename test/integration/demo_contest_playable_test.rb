require "test_helper"

# The point of seeding a demo contest into a fresh worktree is that you can
# PLAY it: find it on /contests, open its board, and make a pick. A row in the
# contests table that 500s on render would satisfy the seed test and still leave
# the worktree with nothing to click.
class DemoContestPlayableTest < ActionDispatch::IntegrationTest
  SPAN_TEAMS = %w[team-a team-b team-c team-d].freeze
  FIRST_KICKOFF = Time.utc(2026, 9, 10, 0, 20)

  # A round-robin, one week per row — a game slug is derived from its two teams,
  # so a pair may meet only once across the span.
  WEEK_PAIRINGS = {
    1 => [%w[team-a team-b], %w[team-c team-d]],
    2 => [%w[team-a team-c], %w[team-b team-d]],
    3 => [%w[team-a team-d], %w[team-b team-c]]
  }.freeze

  setup do
    # Anchor "now" a week before the fixture's first kickoff — see the same
    # guard in test/seeds/nfl_demo_contest_seed_test.rb. Picking a team is only
    # legal before kickoff (Entry#toggle_selection!), so on the real clock this
    # file would start failing on 2026-09-10 and redden every PR in the repo.
    travel_to FIRST_KICKOFF - 1.week
    SeasonConfig.set_current!(1)
    build_weekly_nfl_slates!
    silence_warnings { load Rails.root.join("db/seeds/nfl_demo_contest.rb") }
    @contest = seed_nfl_demo_contest!
  end

  test "the demo contest is listed on the contests index" do
    get contests_path

    assert_response :success
    assert_includes response.body, "NFL 2026 Weeks 1-3"
    assert_includes response.body, contest_path(@contest)
  end

  test "the demo contest board renders every pickable team" do
    get contest_path(@contest)

    assert_response :success
    SPAN_TEAMS.each do |team_slug|
      assert_includes response.body, Team.find_by!(slug: team_slug).name
    end
  end

  test "a signed-in player can pick a team in the demo contest" do
    log_in_as(users(:sam))
    matchup = @contest.pickable_matchups.first

    assert_difference ["Entry.count", "Selection.count"], 1 do
      post toggle_selection_contest_path(@contest), params: { matchup_id: matchup.id }, as: :json
    end

    assert_response :success
    assert_equal({ matchup.id.to_s => true }, JSON.parse(response.body)["selections"])
  end

  private

  # The weekly source slates db/seeds/nfl_2026.rb +
  # db/seeds/nfl_expected_team_totals_2026.rb build in a real seed run.
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
            expected_score: 24.5 - SPAN_TEAMS.index(team_slug),
            status: "pending"
          )
        end
      end
    end
  end
end
