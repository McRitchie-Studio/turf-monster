require "test_helper"

class ContestKnockoutSlatesTest < ActionDispatch::IntegrationTest
  setup do
    SeasonConfig.set_current!(1)
    seed_real_knockout_teams!
    @teams_by_code = Team.where(short_name: WorldCup2026KnockoutSeed.required_real_team_codes).index_by(&:short_name)
    WorldCup2026KnockoutSeed.call(teams_by_code: @teams_by_code, ranking_odds: {})
    log_in_as(users(:alex))
  end

  test "contest generator renders seeded knockout slates" do
    get generator_contests_path

    assert_response :success
    assert_includes response.body, "World Cup 2026 Round of 32"
    assert_includes response.body, "World Cup 2026 Final"
    assert_includes response.body, "32 matchups available"
    assert_includes response.body, "2 picks required"
  end

  test "new contest defaults to selected knockout slate kickoff" do
    slate = Slate.find_by!(name: "World Cup 2026 Round of 32")

    Solana::Vault.stub :new, FakeVault.new(seasons: [{ season_id: 1, name: "World Cup 2026" }]) do
      get new_contest_path(slate_id: slate.id, contest_type: "medium")
    end

    assert_response :success
    assert_includes response.body, "World Cup 2026 Round of 32"
    assert_includes response.body, "2026-06-28T19:00:00Z"
  end

  test "seeded final slate contests are enterable with every available matchup" do
    slate = Slate.find_by!(name: "World Cup 2026 Final")

    # The knockout seed carries the REAL fixture kickoff (2026-07-19T19:00:00Z), so
    # once that instant passed this test began entering a contest that had already
    # locked. Enter from before kickoff — the open-contest state the test means to
    # exercise — instead of depending on the wall clock.
    travel_to slate.starts_at - 1.day do
      contest = Contest.create!(
        name: "World Cup Final Test",
        slug: "world-cup-final-test",
        slate: slate,
        contest_type: "standard",
        entry_fee_cents: 19_00,
        max_entries: 29,
        status: :open,
        starts_at: slate.starts_at
      )
      entry = contest.entries.create!(user: users(:sam), status: :cart)
      slate.slate_matchups.each { |matchup| entry.selections.create!(slate_matchup: matchup) }

      entry.confirm!(tx_signature: "world-cup-final-paid")

      assert_equal 2, contest.picks_required
      assert entry.reload.active?
    end
  end

  private

  def seed_real_knockout_teams!
    WorldCup2026KnockoutSeed.required_real_team_codes.each do |code|
      Team.find_or_create_by!(short_name: code) do |team|
        team.name = "Team #{code}"
        team.location = "Team #{code}"
        team.emoji = "🏳️"
        team.color_dark = "#111827"
        team.color_light = "#F9FAFB"
        team.sport = "soccer"
        team.league = "fifa"
        team.division = "Test"
        team.rivals = []
      end
    end
  end
end
