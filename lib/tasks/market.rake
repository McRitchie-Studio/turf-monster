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

namespace :market do
  # Step 1 of docs/workflows/market-snapshot.md for the NFL: pull DraftKings'
  # lines (via ESPN — see Nfl::Espn::MarketLines) into the checked-in dataset.
  # DRY RUN unless APPLY=1, and it writes a FILE only; `market:snapshot` is
  # still what puts numbers in the database.
  #
  #   bin/rails market:pull WEEKS=4,5,6
  #   APPLY=1 bin/rails market:pull WEEKS=4,5,6
  desc "Pull DraftKings lines for whole NFL weeks into the seed dataset (dry run unless APPLY=1)"
  task pull: :environment do
    result = Market::Runner.pull(apply: ENV["APPLY"] == "1")
    Market::Runner.print_pull(result)
    abort "REFUSED: #{result.refusal}" if result.refusal

    puts result.applied ? "WROTE #{result.path}" : "Dry run only. Re-run with APPLY=1 to write the dataset."
  end

  # The whole benchmark rebuild in one command: pull the lines, ingest them,
  # re-read the span's expected scores, and reprice it under the current rule.
  #
  # DRY RUN unless APPLY=1 — but read what a dry run can and cannot tell you. It
  # skips the INGEST, so no expected score moves, so RepriceSpanSlate sees no
  # changed price and its paid-pick branch (which fires only on a price that
  # actually changes) stays silent. A dry run therefore names the refusals it
  # can see WITHOUT fresh numbers — a started slate, schedule drift — and the
  # APPLY can still refuse on paid picks where the dry run said nothing.
  #
  #   bin/rails market:refresh WEEKS=4,5,6 SPAN=nfl-2026-weeks-4-6
  #   APPLY=1 REPRICE_PAID_PICKS=nfl-2026-weeks-4-6 \
  #     bin/rails market:refresh WEEKS=4,5,6 SPAN=nfl-2026-weeks-4-6
  desc "Rebuild a span's benchmarks from fresh DraftKings lines (dry run unless APPLY=1)"
  task refresh: :environment do
    apply = ENV["APPLY"] == "1"
    span = Slate.find_by(slug: ENV["SPAN"].to_s) || abort("set SPAN=<span-slate-slug>")

    puts "market:refresh #{span.name} — #{apply ? 'APPLY' : 'DRY RUN'}"
    puts "1/4 pull"
    pull = Market::Runner.pull(apply: apply)
    Market::Runner.print_pull(pull)
    abort "REFUSED at the pull: #{pull.refusal}" if pull.refusal

    if apply
      puts "2/4 ingest"
      Market::Runner.weeks.each do |week|
        ingested = Nfl::CacheExpectedTeamTotals.call(year: Market::Runner.year, week: week)
        puts "    week #{week}: #{ingested.projections_upserted} team rows " \
             "(snapshot ##{ingested.market_snapshot.id})"
      end
    else
      puts "2/4 ingest — skipped on a dry run (the dataset has not been written)"
    end

    puts "3/4 refresh + 4/4 reprice"
    result = Nfl::RefreshSpanSlate.call(
      slate: span, apply: apply, reprice_paid_picks: ENV["REPRICE_PAID_PICKS"] == span.slug
    )
    Market::Runner.print_refresh(result)
    abort "REFUSED: #{result.refusal}" if result.refusal

    puts result.applied ? "APPLIED." : "Dry run only. Re-run with APPLY=1 to write."
  end
end
