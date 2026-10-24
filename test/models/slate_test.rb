require "test_helper"

class SlateTest < ActiveSupport::TestCase
  setup do
    @slate = slates(:one)
  end

  test "slug is set on save" do
    slate = Slate.create!(name: "My New Slate")
    assert_equal "my-new-slate", slate.slug
  end

  test "has many slate_matchups" do
    assert_equal 6, @slate.slate_matchups.count
  end

  test "has many contests" do
    assert_includes @slate.contests, contests(:one)
  end

  test "validates name presence" do
    slate = Slate.new(name: nil)
    assert_not slate.valid?
    assert_includes slate.errors[:name], "can't be blank"
  end

  test "first_game_starts_at returns the earliest linked kickoff" do
    later = Game.create!(week: 1, home_team_slug: "team-a", away_team_slug: "team-b", kickoff_at: 2.days.from_now, status: "scheduled")
    first = Game.create!(home_team_slug: "team-c", away_team_slug: "team-d", kickoff_at: 1.day.from_now, status: "scheduled")
    slate_matchups(:m1).update!(game_slug: later.slug)
    slate_matchups(:m3).update!(game_slug: first.slug)

    assert_equal first, @slate.first_game
    assert_equal first.kickoff_at.to_i, @slate.first_game_starts_at.to_i
  end
end
