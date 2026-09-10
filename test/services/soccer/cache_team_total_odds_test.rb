require "test_helper"
require "tempfile"

class Soccer::CacheTeamTotalOddsTest < ActiveSupport::TestCase
  setup do
    @mexico = Team.create!(name: "Mexico Test", slug: "mexico-test", short_name: "MXT")
    @rsa = Team.create!(name: "South Africa Test", slug: "south-africa-test", short_name: "RST")
    @slate = Slate.create!(name: "Group Stage — Test Matchday", starts_at: 2.days.from_now)
    @matchup = SlateMatchup.create!(
      slate: @slate, team_slug: @mexico.slug, opponent_team_slug: @rsa.slug, status: "pending"
    )
  end

  test "writes odds and fills a blank line onto fifa matchups" do
    result = Soccer::CacheTeamTotalOdds.call(path: dataset_path)

    assert_equal 2, result.rows
    assert_equal 1, result.matchups_updated
    assert_equal ["ZZZ"], result.teams_missing

    @matchup.reload
    assert_equal(-165, @matchup.team_total_over_odds)
    assert_equal 100, @matchup.team_total_under_odds
    assert_equal BigDecimal("1.5"), @matchup.expected_score
  end

  test "never clobbers an existing goals expectation and stays idempotent" do
    @matchup.update!(expected_score: 2.0)

    2.times { Soccer::CacheTeamTotalOdds.call(path: dataset_path) }

    @matchup.reload
    assert_equal BigDecimal("2.0"), @matchup.expected_score
    assert_equal(-165, @matchup.team_total_over_odds)
  end

  test "skips matchups on NFL slates" do
    nfl_slate = Slate.create!(name: "NFL 2026 Week 1", starts_at: 3.days.from_now)
    nfl_matchup = SlateMatchup.create!(
      slate: nfl_slate, team_slug: @mexico.slug, opponent_team_slug: @rsa.slug, status: "pending"
    )

    Soccer::CacheTeamTotalOdds.call(path: dataset_path)

    assert_nil nfl_matchup.reload.team_total_over_odds
  end

  test "raises for a missing dataset file" do
    error = assert_raises(ArgumentError) do
      Soccer::CacheTeamTotalOdds.call(path: "/nonexistent/odds.json")
    end
    assert_match(/Missing DK team totals dataset/, error.message)
  end

  private

  def dataset_path
    file = Tempfile.new(["dk_totals", ".json"])
    file.write(JSON.generate([
      { "team_name" => "Mexico Test", "short_name" => "MXT", "opponent_short_name" => "RST",
        "line" => 1.5, "over_odds" => -165, "under_odds" => 100 },
      { "team_name" => "Nowhere", "short_name" => "ZZZ", "opponent_short_name" => "MXT",
        "line" => 0.5, "over_odds" => -155, "under_odds" => -105 }
    ]))
    file.close
    file.path
  end
end
