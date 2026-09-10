require "test_helper"
require "tempfile"

# MONEY-SAFETY regression suite for Nfl::CacheExpectedTeamTotals.
#
# Settlement (Selection#compute_points!) reads the STORED slate_matchups.turf_score
# and never recomputes it. So two rebuild behaviours are money hazards:
#
#   (a) rank_slate_matchups! rewriting turf_score on a matchup a player has
#       already picked — silently re-prices committed money.
#   (b) delete_stale_rows deleting projections for weeks the current CSV did not
#       cover — a single-week rebuild would wipe every other week.
#
# Each test below is written to be RED against an unguarded service and GREEN
# once the guard lands (mutation-verified).
class Nfl::CacheExpectedTeamTotalsSafetyTest < ActiveSupport::TestCase
  setup { @tempfiles = [] }
  teardown { @tempfiles.each { |f| f.close! rescue nil } }

  # ── Hazard (a): a rebuild must not re-price a picked matchup ──────────────
  test "rebuild does NOT change turf_score once a Selection exists on the matchup" do
    # Run 1: team-a is the favorite → rank 1 → turf_score 1.0; team-b → 2.0.
    Nfl::CacheExpectedTeamTotals.call(path: csv([
      "5,team-b,team-a,team-a,-7,50,src,2026-05-26,https://example.test/x,wk5"
    ]))

    slate = Slate.find_by!(name: "NFL 2026 Week 5")
    picked = slate.slate_matchups.find_by!(team_slug: "team-a")
    unpicked = slate.slate_matchups.find_by!(team_slug: "team-b")
    assert_equal BigDecimal("1.0"), picked.turf_score, "precondition: picked prices 1.0"
    assert_equal BigDecimal("2.0"), unpicked.turf_score, "precondition: unpicked prices 2.0"

    # A player commits a pick on team-a at the 1.0 price.
    entry = Entry.create!(user: users(:alex), contest: contests(:one), status: :active)
    Selection.create!(entry: entry, slate_matchup: picked)

    # Run 2: same game, but now team-b is the heavy favorite. A live re-rank
    # would flip team-a to rank 2 (turf_score 2.0) and team-b to rank 1 (1.0).
    result = Nfl::CacheExpectedTeamTotals.call(path: csv([
      "5,team-b,team-a,team-b,-14,50,src,2026-05-26,https://example.test/x,wk5"
    ]))

    # THE GUARD: the picked matchup keeps its frozen 1.0 price (would be 2.0
    # without the guard — this is the mutation-discriminating assertion).
    assert_equal BigDecimal("1.0"), picked.reload.turf_score,
      "picked matchup was re-priced after a Selection existed — settlement corruption"
    assert_equal 1, picked.rank, "picked matchup rank must stay frozen too"

    # And the rebuild is genuinely live: the UNPICKED matchup re-ranked to 1.0,
    # proving the guard is surgical, not a blanket no-op.
    assert_equal BigDecimal("1.0"), unpicked.reload.turf_score,
      "unpicked matchup should re-rank freely on a rebuild"
    assert_equal 1, result.rows
  end

  # ── Hazard (b): the stale sweep must not reach outside the built weeks ────
  test "stale sweep removes ONLY the rebuilt week, leaving other weeks intact" do
    # Week 3 has one game.
    Nfl::CacheExpectedTeamTotals.call(path: csv([
      "3,team-d,team-c,team-c,-3,44,src,2026-05-26,https://example.test/x,wk3"
    ]))
    # Week 5 has two games.
    Nfl::CacheExpectedTeamTotals.call(path: csv([
      "5,team-b,team-a,team-a,-3,48,src,2026-05-26,https://example.test/x,wk5",
      "5,team-f,team-e,team-e,-3,50,src,2026-05-26,https://example.test/x,wk5"
    ]))

    assert_equal 2, NflTeamTotalProjection.where(year: 2026, week: 3).count
    assert_equal 4, NflTeamTotalProjection.where(year: 2026, week: 5).count

    # Rebuild week 5 with only the first game — the team-e/team-f game is dropped.
    result = Nfl::CacheExpectedTeamTotals.call(path: csv([
      "5,team-b,team-a,team-a,-3,48,src,2026-05-26,https://example.test/x,wk5"
    ]))

    # Week 3 is untouched by a week-5 rebuild (would be 0 under a year-wide
    # sweep — this is the mutation-discriminating assertion).
    assert_equal 2, NflTeamTotalProjection.where(year: 2026, week: 3).count,
      "week-3 projections were deleted by a week-5 rebuild — cross-week data loss"
    # Within week 5 the stale game IS cleaned up (scoping did not disable it).
    assert_equal 2, NflTeamTotalProjection.where(year: 2026, week: 5).count
    assert_equal 0, NflTeamTotalProjection.where(year: 2026, week: 5, team_slug: %w[team-e team-f]).count
    assert_equal 2, result.stale_deleted, "only the two stale week-5 rows should be swept"
  end

  private

  # Writes a CSV with the fixed team-totals header and the given data rows,
  # returns the file path.
  def csv(rows)
    file = Tempfile.new(["team_totals", ".csv"])
    file.write("week,away_team_slug,home_team_slug,favorite_team_slug,favorite_spread,game_total,source,source_published_on,source_url,source_text\n")
    rows.each { |row| file.write("#{row}\n") }
    file.close
    @tempfiles << file
    file.path
  end
end
