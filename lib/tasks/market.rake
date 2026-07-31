namespace :market do
  # The per-week market capture from docs/workflows/market-snapshot.md step 3.
  #
  # Unlike the season-wide nfl:expected_team_totals_cache, this never loads the
  # schedule seed (db/seeds/nfl_2026.rb) — it is the pure ingest the SOP
  # describes, so it cannot trip the unguarded kickoff-time re-rank. It reads the
  # checked-in dataset (or CSV_PATH), narrows to WEEK when given, upserts the
  # week's projections, and records one MarketSnapshot artifact for the run.
  #
  #   bin/rails market:snapshot SPORT=nfl WEEK=3
  #   bin/rails market:snapshot SPORT=nfl WEEK=3 CSV_PATH=/path/to/refreshed.csv
  desc "Capture a per-week market snapshot (pure ingest + MarketSnapshot artifact)"
  task snapshot: :environment do
    sport = ENV.fetch("SPORT", Nfl::CacheExpectedTeamTotals::DEFAULT_SPORT).downcase
    unless sport == "nfl"
      abort "market:snapshot only implements sport=nfl today (got #{sport.inspect}). " \
            "Other sports are 🔨 PLANNED — see docs/workflows/market-snapshot.md."
    end

    year = ENV.fetch("YEAR", Nfl::CacheExpectedTeamTotals::DEFAULT_YEAR)
    week = ENV["WEEK"].presence && Integer(ENV["WEEK"])
    path = ENV["CSV_PATH"].presence || Nfl::CacheExpectedTeamTotals::DEFAULT_PATH

    result = Nfl::CacheExpectedTeamTotals.call(sport: sport, year: year, path: path, week: week)
    snapshot = result.market_snapshot
    scope = week ? "week #{week}" : "season"

    puts "market:snapshot #{sport} #{result.year} #{scope}: " \
         "#{result.projections_upserted} team rows " \
         "(#{snapshot.posted_count} posted, #{snapshot.derived_count} derived), " \
         "#{result.stale_deleted} stale deleted."
    puts "  artifact ##{snapshot.id} · #{snapshot.dataset_path} · checksum #{snapshot.checksum[0, 12]}…"
  end
end
