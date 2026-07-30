require "test_helper"
require "tempfile"

class Nfl::CacheExpectedTeamTotalsTest < ActiveSupport::TestCase
  test "derives home and away expected points from total and home spread" do
    totals = Nfl::CacheExpectedTeamTotals.derive(game_total: "47.5", home_spread: "-3.5")

    assert_equal BigDecimal("25.50"), totals.fetch(:home)
    assert_equal BigDecimal("22.00"), totals.fetch(:away)
  end

  test "caches projections and creates missing week slate data" do
    result = Nfl::CacheExpectedTeamTotals.call(path: csv_path)

    assert_equal 1, result.rows
    assert_equal 1, result.games_created
    assert_equal 1, result.slates_created
    assert_equal 2, result.matchups_created
    assert_equal 2, result.projections_upserted

    game = Game.find_by!(slug: "team-a-vs-team-b")
    slate = Slate.find_by!(name: "NFL 2026 Week 18")
    home_projection = NflTeamTotalProjection.find_by!(year: 2026, week: 18, game_slug: game.slug, team_slug: "team-a")
    away_projection = NflTeamTotalProjection.find_by!(year: 2026, week: 18, game_slug: game.slug, team_slug: "team-b")

    assert_equal slate, home_projection.slate
    assert home_projection.home?
    assert_equal BigDecimal("25.00"), home_projection.expected_points
    assert_equal BigDecimal("22.00"), away_projection.expected_points
    assert_equal "Team A Lookahead", home_projection.source_text
    assert_equal 2, slate.slate_matchups.where(game_slug: game.slug).count

    home_matchup = slate.slate_matchups.find_by!(team_slug: "team-a")
    away_matchup = slate.slate_matchups.find_by!(team_slug: "team-b")
    assert_equal BigDecimal("25.0"), home_matchup.dk_goals_expectation
    assert_equal BigDecimal("22.0"), away_matchup.dk_goals_expectation
    assert_equal 1, home_matchup.rank
    assert_equal 2, away_matchup.rank
  end

  test "re-running cache updates rows without duplicating projections" do
    Nfl::CacheExpectedTeamTotals.call(path: csv_path)
    Nfl::CacheExpectedTeamTotals.call(path: csv_path)

    assert_equal 2, NflTeamTotalProjection.where(year: 2026, week: 18, game_slug: "team-a-vs-team-b").count
    assert_equal 1, Game.where(slug: "team-a-vs-team-b").count
  end

  # ── Artifact (acceptance #4): every run records a MarketSnapshot row ──────────
  test "records a MarketSnapshot artifact and links every projection to it" do
    result = Nfl::CacheExpectedTeamTotals.call(path: csv_path)

    snapshot = result.market_snapshot
    assert_kind_of MarketSnapshot, snapshot
    assert snapshot.persisted?
    assert_equal "nfl", snapshot.sport
    assert_equal 2026, snapshot.year
    assert_nil snapshot.week, "a season-wide run captures no single week"
    assert_equal 2, snapshot.row_count
    assert_equal 0, snapshot.posted_count
    assert_equal 2, snapshot.derived_count
    assert snapshot.checksum.present?, "the ingested dataset is pinned by checksum"
    assert snapshot.dataset_path.present?

    projections = NflTeamTotalProjection.where(year: 2026, week: 18, game_slug: "team-a-vs-team-b")
    assert_equal 2, projections.count
    assert projections.all? { |p| p.market_snapshot_id == snapshot.id }, "each projection belongs to the run"
    assert projections.all? { |p| p.basis == "derived" }, "no posted line -> derived basis"
  end

  # ── Basis (acceptance #2, #3): posted preferred, derived fallback ────────────
  test "stamps basis posted and uses DK's posted line as-is when the CSV posts a total" do
    result = Nfl::CacheExpectedTeamTotals.call(path: posted_csv_path)

    home = NflTeamTotalProjection.find_by!(year: 2026, week: 18, game_slug: "team-a-vs-team-b", team_slug: "team-a")
    away = NflTeamTotalProjection.find_by!(year: 2026, week: 18, game_slug: "team-a-vs-team-b", team_slug: "team-b")

    # Posted side: DK's number is used as-is (not the derived 25.0), basis "posted".
    assert home.posted?
    assert_equal "posted", home.basis
    assert_equal BigDecimal("27.5"), home.posted_line
    assert_equal BigDecimal("27.5"), home.expected_points, "posted line is used as-is, preferred over derived"
    assert_equal(-140, home.over_odds)
    assert_equal 110, home.under_odds

    # Unposted side: falls back to the derived value, basis "derived".
    assert_equal "derived", away.basis
    assert_nil away.posted_line
    assert_equal BigDecimal("22.00"), away.expected_points

    assert_equal 1, result.market_snapshot.posted_count
    assert_equal 1, result.market_snapshot.derived_count
  end

  # ── Week filter (acceptance #1 on the ingest side): market:snapshot WEEK=n ────
  test "week filter narrows the run to one week and records it on the snapshot" do
    Nfl::CacheExpectedTeamTotals.call(path: multiweek_csv_path) # weeks 3 and 5
    result = Nfl::CacheExpectedTeamTotals.call(path: multiweek_csv_path, week: 5)

    assert_equal 5, result.market_snapshot.week
    assert_equal 1, result.rows, "only the week-5 row is ingested"
    assert_equal 2, NflTeamTotalProjection.where(year: 2026, week: 3).count, "week 3 is untouched by a week-5 run"
  end

  test "week filter raises when no CSV row matches the requested week" do
    assert_raises(ArgumentError) { Nfl::CacheExpectedTeamTotals.call(path: csv_path, week: 7) }
  end

  private

  def csv_path
    file = Tempfile.new(["team_totals", ".csv"])
    file.write <<~CSV
      week,away_team_slug,home_team_slug,favorite_team_slug,favorite_spread,game_total,source,source_published_on,source_url,source_text
      18,team-b,team-a,team-a,-3,47,test_source,2026-05-26,https://example.test/team-totals,Team A Lookahead
    CSV
    file.close
    file.path
  end

  # Home side carries DK's posted team total (+ odds); away side is left unposted.
  def posted_csv_path
    file = Tempfile.new(["team_totals_posted", ".csv"])
    file.write <<~CSV
      week,away_team_slug,home_team_slug,favorite_team_slug,favorite_spread,game_total,source,source_published_on,source_url,source_text,home_posted_line,home_over_odds,home_under_odds,away_posted_line,away_over_odds,away_under_odds
      18,team-b,team-a,team-a,-3,47,test_source,2026-05-26,https://example.test/team-totals,Team A Lookahead,27.5,-140,110,,,
    CSV
    file.close
    file.path
  end

  def multiweek_csv_path
    file = Tempfile.new(["team_totals_multiweek", ".csv"])
    file.write <<~CSV
      week,away_team_slug,home_team_slug,favorite_team_slug,favorite_spread,game_total,source,source_published_on,source_url,source_text
      3,team-d,team-c,team-c,-3,44,test_source,2026-05-26,https://example.test/team-totals,W3
      5,team-b,team-a,team-a,-3,48,test_source,2026-05-26,https://example.test/team-totals,W5
    CSV
    file.close
    file.path
  end
end
