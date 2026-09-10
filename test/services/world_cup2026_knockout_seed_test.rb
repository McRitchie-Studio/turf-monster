require "test_helper"

class WorldCup2026KnockoutSeedTest < ActiveSupport::TestCase
  setup do
    seed_real_knockout_teams!
    @teams_by_code = Team.where(short_name: WorldCup2026KnockoutSeed.required_real_team_codes).index_by(&:short_name)
  end

  test "seeds all knockout slates games matchups and placeholders" do
    assert_difference -> { Slate.count }, 6 do
      assert_difference -> { Game.count }, 32 do
        assert_difference -> { SlateMatchup.count }, 64 do
          WorldCup2026KnockoutSeed.call(teams_by_code: @teams_by_code, ranking_odds: {})
        end
      end
    end

    round_of_32 = Slate.find_by!(name: "World Cup 2026 Round of 32")
    round_of_16 = Slate.find_by!(name: "World Cup 2026 Round of 16")
    final = Slate.find_by!(name: "World Cup 2026 Final")

    assert_equal 32, round_of_32.slate_matchups.count
    assert_equal 16, round_of_16.slate_matchups.count
    assert_equal 2, final.slate_matchups.count
    assert_equal Time.iso8601("2026-06-28T19:00:00Z"), round_of_32.first_game_starts_at
    assert_equal Time.iso8601("2026-07-19T19:00:00Z"), final.first_game_starts_at

    assert_equal %w[MEX ECU], fixture_codes(79)
    assert_equal %w[ENG COD], fixture_codes(80)
    assert_equal %w[BEL SEN], fixture_codes(82)
    assert_equal %w[POR CRO], fixture_codes(83)
    assert_equal %w[ESP AUT], fixture_codes(84)
    assert_equal %w[SUI ALG], fixture_codes(85)
    assert_equal %w[COL GHA], fixture_codes(87)
    assert_equal %w[CAN W75], fixture_codes(90)

    assert_equal 31, WorldCup2026KnockoutSeed.placeholder_codes.size
    refute_includes WorldCup2026KnockoutSeed.placeholder_codes, "3CEFHI"
    refute_includes WorldCup2026KnockoutSeed.placeholder_codes, "W73"
    assert Team.exists?(short_name: "W101", name: "Winner Match 101")
    assert_equal "Knockout Slot", Team.find_by!(short_name: "RU101").division
  end

  test "seeding is idempotent" do
    WorldCup2026KnockoutSeed.call(teams_by_code: @teams_by_code, ranking_odds: {})

    assert_no_difference -> { Team.count } do
      assert_no_difference -> { Slate.count } do
        assert_no_difference -> { Game.count } do
          assert_no_difference -> { SlateMatchup.count } do
            WorldCup2026KnockoutSeed.call(teams_by_code: @teams_by_code, ranking_odds: {})
          end
        end
      end
    end
  end

  test "reseeding preserves completed knockout game status and scores" do
    WorldCup2026KnockoutSeed.call(teams_by_code: @teams_by_code, ranking_odds: {})

    game = seeded_game_for_fixture(73)
    game.update!(status: "completed", home_score: 0, away_score: 1)

    WorldCup2026KnockoutSeed.call(teams_by_code: @teams_by_code, ranking_odds: {})

    game.reload
    assert_equal "completed", game.status
    assert_equal 0, game.home_score
    assert_equal 1, game.away_score
  end

  test "reseeding removes stale unresolved round of 32 placeholders" do
    slate = Slate.create!(name: "World Cup 2026 Round of 32")
    stale_team = Team.create!(
      name: "Best 3rd C/E/F/H/I",
      short_name: "3CEFHI",
      location: "World Cup bracket",
      emoji: "🏆",
      color_dark: "#111827",
      color_light: "#FACC15",
      sport: "soccer",
      league: "fifa",
      division: "Knockout Slot",
      rivals: []
    )
    mexico = @teams_by_code.fetch("MEX")
    stale_game = Game.create!(
      home_team_slug: mexico.slug,
      away_team_slug: stale_team.slug,
      kickoff_at: Time.iso8601("2026-07-01T01:00:00Z"),
      venue: "Mexico City Stadium, Mexico City",
      status: "scheduled"
    )
    SlateMatchup.create!(slate: slate, team_slug: stale_team.slug, opponent_team_slug: mexico.slug, game_slug: stale_game.slug)

    WorldCup2026KnockoutSeed.call(teams_by_code: @teams_by_code, ranking_odds: {})

    assert_equal 32, slate.reload.slate_matchups.count
    assert_equal %w[MEX ECU], fixture_codes(79)
    refute SlateMatchup.exists?(team_slug: stale_team.slug)
    refute Game.exists?(slug: stale_game.slug)
    refute Team.exists?(short_name: "3CEFHI")
  end

  test "reseeding removes stale resolved advancement placeholders" do
    slate = Slate.create!(name: "World Cup 2026 Round of 16")
    stale_team = Team.create!(
      name: "Winner Match 73",
      short_name: "W73",
      location: "World Cup bracket",
      emoji: "🏆",
      color_dark: "#111827",
      color_light: "#FACC15",
      sport: "soccer",
      league: "fifa",
      division: "Knockout Slot",
      rivals: []
    )
    unresolved_team = Team.create!(
      name: "Winner Match 75",
      short_name: "W75",
      location: "World Cup bracket",
      emoji: "🏆",
      color_dark: "#111827",
      color_light: "#FACC15",
      sport: "soccer",
      league: "fifa",
      division: "Knockout Slot",
      rivals: []
    )
    stale_game = Game.create!(
      home_team_slug: stale_team.slug,
      away_team_slug: unresolved_team.slug,
      kickoff_at: Time.iso8601("2026-07-04T17:00:00Z"),
      venue: "Houston Stadium, Houston",
      status: "scheduled"
    )
    SlateMatchup.create!(
      slate: slate,
      team_slug: stale_team.slug,
      opponent_team_slug: unresolved_team.slug,
      game_slug: stale_game.slug
    )

    WorldCup2026KnockoutSeed.call(teams_by_code: @teams_by_code, ranking_odds: {})

    assert_equal 16, slate.reload.slate_matchups.count
    assert_equal %w[CAN W75], fixture_codes(90)
    refute SlateMatchup.exists?(team_slug: stale_team.slug)
    refute Game.exists?(slug: stale_game.slug)
    refute Team.exists?(short_name: "W73")
  end

  private

  def fixture_codes(match_number)
    fixture = WorldCup2026KnockoutSeed::FIXTURES.find { |candidate| candidate[:match] == match_number }
    [fixture[:home], fixture[:away]]
  end

  def seeded_game_for_fixture(match_number)
    home_code, away_code = fixture_codes(match_number)
    home_team = Team.find_by!(short_name: home_code)
    away_team = Team.find_by!(short_name: away_code)
    Game.find_by!(home_team_slug: home_team.slug, away_team_slug: away_team.slug)
  end

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
