require "test_helper"
require "csv"

# INTEGRATION: the real checked-in dataset, through the real ingest, into
# projections + slate matchups.
#
# The unit guard (test/seeds/nfl_expected_team_totals_csv_test.rb) reads the file
# as text. This one runs weeks 4-9 through Nfl::CacheExpectedTeamTotals and
# asserts what a contest is actually priced on: one projection per team per game,
# basis "derived" (no DK team totals are posted — only the game-total and spread
# primitives), and the two sides of a game summing to exactly that game total.
class Nfl::ExpectedTeamTotalsDkIngestTest < ActiveSupport::TestCase
  PATH = Rails.root.join("db/seeds/data/nfl/2026_expected_team_totals.csv")

  setup do
    @rows = CSV.read(PATH, headers: true).select { |r| (4..9).cover?(r["week"].to_i) }
    slugs = @rows.flat_map { |r| [r["home_team_slug"], r["away_team_slug"]] }.uniq
    slugs.each do |slug|
      Team.find_or_create_by!(slug: slug) do |team|
        team.name = slug.tr("-", " ").split.map(&:capitalize).join(" ")
        team.sport = "football"
        team.league = "nfl"
      end
    end
  end

  test "ingesting week 4 lands one derived projection per team per game" do
    week_4 = @rows.select { |r| r["week"].to_i == 4 }

    result = Nfl::CacheExpectedTeamTotals.call(year: 2026, path: PATH, week: 4)

    assert_equal week_4.size * 2, result.projections_upserted
    projections = NflTeamTotalProjection.where(year: 2026, week: 4)
    assert_equal week_4.size * 2, projections.count
    assert_equal ["derived"], projections.map(&:basis).uniq,
                 "no DraftKings team total is posted, so every side derives from total + spread"
    assert_equal 0, result.market_snapshot.posted_count
  end

  test "each game's two expected scores sum to that game's DraftKings total" do
    Nfl::CacheExpectedTeamTotals.call(year: 2026, path: PATH, week: 4)

    @rows.select { |r| r["week"].to_i == 4 }.each do |row|
      game_slug = "#{row['home_team_slug']}-vs-#{row['away_team_slug']}"
      sides = NflTeamTotalProjection.where(year: 2026, week: 4, game_slug: game_slug)

      assert_equal 2, sides.count, "#{game_slug} must have both sides"
      assert_equal BigDecimal(row["game_total"].to_s), sides.sum(&:expected_points),
                   "#{game_slug} sides must sum to the posted game total"
    end
  end

  test "the favorite outscores the underdog in every ingested week 4 game" do
    Nfl::CacheExpectedTeamTotals.call(year: 2026, path: PATH, week: 4)

    @rows.select { |r| r["week"].to_i == 4 }.each do |row|
      next if BigDecimal(row["favorite_spread"].to_s).zero?

      game_slug = "#{row['home_team_slug']}-vs-#{row['away_team_slug']}"
      by_slug = NflTeamTotalProjection.where(year: 2026, week: 4, game_slug: game_slug).index_by(&:team_slug)
      favorite = by_slug.fetch(row["favorite_team_slug"])
      underdog = by_slug.values.find { |p| p.team_slug != favorite.team_slug }

      # The sign convention is only correct in one direction: flip it and the
      # underdog is handed the points, which inverts the whole slate ranking.
      assert favorite.expected_points > underdog.expected_points,
             "#{game_slug}: favorite #{favorite.team_slug} (#{favorite.expected_points}) " \
             "must outscore #{underdog.team_slug} (#{underdog.expected_points})"
    end
  end

  test "ingesting week 4 leaves the other weeks' projections alone" do
    Nfl::CacheExpectedTeamTotals.call(year: 2026, path: PATH, week: 5)
    week_5_ids = NflTeamTotalProjection.where(year: 2026, week: 5).pluck(:id).sort
    assert_predicate week_5_ids.size, :positive?, "precondition: week 5 ingested"

    Nfl::CacheExpectedTeamTotals.call(year: 2026, path: PATH, week: 4)

    # delete_stale_rows is scoped to @touched_weeks — a week-4 run must not
    # sweep week 5, which is what would silently shorten a 4-6 span slate.
    assert_equal week_5_ids, NflTeamTotalProjection.where(year: 2026, week: 5).pluck(:id).sort
  end

  test "the ingest builds the weekly slate its span will be assembled from" do
    Nfl::CacheExpectedTeamTotals.call(year: 2026, path: PATH, week: 6)

    slate = Slate.find_by!(name: "NFL 2026 Week 6")
    week_6 = @rows.select { |r| r["week"].to_i == 6 }

    assert_equal 6, slate.week
    assert_equal "nfl", slate.sport
    assert_equal week_6.size * 2, slate.slate_matchups.count,
                 "two matchups per game — the rows Nfl::BuildSpanSlate copies"
    assert_equal week_6.size * 2, slate.slate_matchups.where.not(rank: nil).count,
                 "every matchup carries a frozen rank"
  end
end
