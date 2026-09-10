require "test_helper"

# [unit] The game slug, and the collision it now avoids.
class GameSeasonSlugTest < ActiveSupport::TestCase
  # Regular-season games keep the bare slug they already carry in production —
  # live SlateMatchup rows point at those strings, and two regular-season
  # meetings of the same teams at the same venue cannot happen.
  test "a regular-season game keeps the bare home-vs-away slug" do
    game = Game.new(home_team_slug: "team-a", away_team_slug: "team-b", season_type: 2, week: 15)

    assert_equal "team-a-vs-team-b", game.name_slug
  end

  test "a game with no season type at all keeps the bare slug" do
    game = Game.new(home_team_slug: "team-a", away_team_slug: "team-b")

    assert_equal "team-a-vs-team-b", game.name_slug
  end

  # The real 2026 schedule has LAC hosting SF in preseason week 3 AND in
  # regular-season week 15, plus SEA hosting DAL in preseason week 2 and
  # regular-season week 13. Two live collisions — so the suffix is load-bearing,
  # not defensive decoration.
  test "preseason and postseason carry a discriminator so they cannot collide" do
    preseason = Game.new(home_team_slug: "team-a", away_team_slug: "team-b", season_type: 1, week: 3)
    regular   = Game.new(home_team_slug: "team-a", away_team_slug: "team-b", season_type: 2, week: 15)
    postseason = Game.new(home_team_slug: "team-a", away_team_slug: "team-b", season_type: 3, week: 1)

    assert_equal "team-a-vs-team-b-pre3", preseason.name_slug
    assert_equal "team-a-vs-team-b-post1", postseason.name_slug
    refute_equal regular.name_slug, preseason.name_slug
    refute_equal regular.name_slug, postseason.name_slug
  end

  test "the season slot scope finds only that week's games in kickoff order" do
    early = Game.create!(slug: "a-vs-b-pre4", home_team_slug: "team-a", away_team_slug: "team-b",
                         season_year: 2026, season_type: 1, week: 4, kickoff_at: 2.hours.from_now)
    late  = Game.create!(slug: "c-vs-d-pre4", home_team_slug: "team-c", away_team_slug: "team-d",
                         season_year: 2026, season_type: 1, week: 4, kickoff_at: 5.hours.from_now)
    Game.create!(slug: "a-vs-b-pre3", home_team_slug: "team-a", away_team_slug: "team-b",
                 season_year: 2026, season_type: 1, week: 3, kickoff_at: 1.day.ago)

    assert_equal [early, late], Game.in_season_slot(year: 2026, season_type: 1, week: 4).to_a
  end
end

# [unit] The slug invariant that SlateMatchup rows depend on.
class GameSlugStabilityTest < ActiveSupport::TestCase
  # Sluggable rewrites `slug` from `name_slug` on every save, and
  # `slate_matchups.game_slug` is a plain string pointing at it. So if adopting
  # a game the odds CSV already created ever CHANGED its slug, every matchup
  # referencing it would orphan and the contest would stop scoring — silently.
  #
  # This is why the regular season keeps the bare slug: the poller stamps
  # season_type 2 onto an existing row, and the name it computes afterwards has
  # to be the name it already had.
  test "stamping a regular-season slot onto an existing game leaves its slug alone" do
    game = Game.create!(home_team_slug: "team-a", away_team_slug: "team-b")
    original = game.slug

    game.update!(season_year: 2026, season_type: 2, week: 15)

    assert_equal original, game.reload.slug
  end

  test "a preseason meeting of the same teams takes a different slug entirely" do
    regular = Game.create!(home_team_slug: "team-a", away_team_slug: "team-b",
                           season_year: 2026, season_type: 2, week: 15)
    preseason = Game.create!(home_team_slug: "team-a", away_team_slug: "team-b",
                             season_year: 2026, season_type: 1, week: 3)

    refute_equal regular.slug, preseason.slug
    # Both survive as their own rows — which is the whole point. (The fixtures
    # already carry a team-a/team-b game, so this counts the two by slug rather
    # than counting the pairing.)
    assert_equal [preseason.slug, regular.slug].sort,
                 Game.where(slug: [regular.slug, preseason.slug]).pluck(:slug).sort
  end
end
