require "test_helper"
require "csv"

# Structural guard on the CHECKED-IN market dataset.
#
# The NFL rows are hand-transcribed (docs/workflows/market-snapshot.md step 2 —
# the DraftKings scraper is 🔨 PLANNED), so the file is exactly where a
# transcription slip lands: a favorite naming a team that is not in the game, a
# spread with the wrong sign, a total that cannot support the spread. None of
# those raise at ingest — they quietly produce a wrong expected_points, which
# ranks a slate, freezes a turf_score, and settles on-chain.
#
# So this asserts the INVARIANTS the derive math depends on, against the real
# file, rather than a fixture that could drift from it.
class NflExpectedTeamTotalsCsvTest < ActiveSupport::TestCase
  PATH = Rails.root.join("db/seeds/data/nfl/2026_expected_team_totals.csv")
  DK_WEEKS = (4..9).to_a.freeze

  setup { @rows = CSV.read(PATH, headers: true) }

  test "every row's favorite is one of the two teams in that game" do
    offenders = @rows.reject do |row|
      [row["home_team_slug"], row["away_team_slug"]].include?(row["favorite_team_slug"])
    end

    # A favorite outside the game falls through home_spread_for's else branch to
    # a 0 spread, which prices the game as a pick'em instead of raising.
    assert_empty offenders.map { |r| "w#{r['week']} #{r['away_team_slug']}@#{r['home_team_slug']} fav=#{r['favorite_team_slug']}" },
                 "favorite_team_slug must name the home or away team"
  end

  test "every favorite_spread is negative or zero" do
    offenders = @rows.select { |row| BigDecimal(row["favorite_spread"].to_s) > 0 }

    # The sign convention is the favorite's spread is NEGATIVE
    # (Nfl::CacheExpectedTeamTotals#home_spread_for). A positive number here
    # flips which side the points go to.
    assert_empty offenders.map { |r| "w#{r['week']} #{r['favorite_team_slug']} #{r['favorite_spread']}" },
                 "favorite_spread must be <= 0"
  end

  test "every game derives a positive expected score for BOTH teams" do
    offenders = @rows.reject do |row|
      derived = Nfl::CacheExpectedTeamTotals.derive(
        game_total: BigDecimal(row["game_total"].to_s),
        home_spread: home_spread_for(row)
      )
      derived.fetch(:home) > 0 && derived.fetch(:away) > 0
    end

    # Catches a spread that outruns its total (e.g. -14 on a 20-point game),
    # which yields a negative team total and a nonsense ranking.
    assert_empty offenders.map { |r| "w#{r['week']} #{r['away_team_slug']}@#{r['home_team_slug']} #{r['favorite_spread']}/#{r['game_total']}" },
                 "both derived team totals must be positive"
  end

  test "no team plays twice in the same week" do
    dupes = @rows.group_by { |row| row["week"] }.flat_map do |week, rows|
      slugs = rows.flat_map { |r| [r["home_team_slug"], r["away_team_slug"]] }
      slugs.tally.select { |_, n| n > 1 }.keys.map { |slug| "w#{week} #{slug}" }
    end

    assert_empty dupes, "a team appearing twice in one week doubles its summed expectation"
  end

  test "weeks 4-9 are sourced from DraftKings with full provenance" do
    dk_rows = @rows.select { |row| DK_WEEKS.include?(row["week"].to_i) }

    assert_equal 88, dk_rows.size, "weeks 4-9 hold 88 games"
    dk_rows.each do |row|
      assert_match(/draftkings/i, row["source"].to_s,
                   "w#{row['week']} #{row['away_team_slug']}@#{row['home_team_slug']} source")
      assert row["source_url"].present?, "w#{row['week']} missing source_url"
      assert row["source_text"].present?, "w#{row['week']} missing source_text"
    end
  end

  test "weeks outside 4-9 are untouched by the DraftKings refresh" do
    others = @rows.reject { |row| DK_WEEKS.include?(row["week"].to_i) }

    assert_equal 184, others.size, "weeks 1-3 and 10-18 hold 184 games"
    assert_equal ["yahoo_sports_2026_lookahead"], others.map { |r| r["source"] }.uniq,
                 "the refresh must not have rewritten a week it did not claim"
  end

  private

  # Mirrors Nfl::CacheExpectedTeamTotals#home_spread_for, which is private.
  def home_spread_for(row)
    spread = BigDecimal(row["favorite_spread"].to_s)
    return spread if row["favorite_team_slug"] == row["home_team_slug"]
    return spread.abs if row["favorite_team_slug"] == row["away_team_slug"]

    BigDecimal("0")
  end
end
