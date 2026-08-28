namespace :nfl do
  desc "Cache expected NFL team totals from the baseline sportsbook CSV"
  task expected_team_totals_cache: :environment do
    year = ENV.fetch("YEAR", Nfl::CacheExpectedTeamTotals::DEFAULT_YEAR)
    path = ENV["CSV_PATH"].presence || Nfl::CacheExpectedTeamTotals::DEFAULT_PATH
    load Rails.root.join("db/seeds/nfl_2026.rb") unless ENV["SKIP_SCHEDULE"] == "1"
    result = Nfl::CacheExpectedTeamTotals.call(year: year, path: path)
    puts "Cached NFL #{result.year} expected team totals: " \
         "#{result.rows} games, #{result.projections_upserted} team rows, " \
         "#{result.games_created} games created, #{result.slates_created} slates created, " \
         "#{result.matchups_created} matchups created, #{result.stale_deleted} stale deleted."
  end

  desc "Refresh the checked-in historical scores dataset from the ESPN scoreboard API"
  task fetch_historical_scores: :environment do
    seasons = ENV["SEASONS"].presence&.split(",")&.map(&:strip) || Nfl::FetchHistoricalScores::DEFAULT_SEASONS
    path = ENV["DATA_PATH"].presence || Nfl::FetchHistoricalScores::DEFAULT_PATH
    result = Nfl::FetchHistoricalScores.call(seasons: seasons, path: path)
    puts "Fetched #{result.games} regular-season finals for #{result.seasons.join(', ')} -> #{result.path}"
  end

  desc "Report expected points by weekly rank from the historical scores dataset"
  task points_distribution: :environment do
    path = ENV["DATA_PATH"].presence || Nfl::PointsDistribution::DEFAULT_PATH
    result = Nfl::PointsDistribution.call(path: path)
    log_fit = result.fits.fetch(:log)
    linear_fit = result.fits.fetch(:linear)

    puts "NFL points distribution — seasons #{result.seasons.join(', ')}"
    puts "Full weeks analyzed: #{result.full_weeks.length} (#{result.partial_weeks_skipped} bye weeks skipped) · " \
         "#{result.games_analyzed} games · league mean #{result.mean_points} pts"
    result.full_weeks.group_by(&:first).each do |season, weeks|
      puts "  #{season}: weeks #{weeks.map(&:last).join(', ')}"
    end
    puts
    puts format("%-6s %-9s %-9s %-9s %-9s %-9s", "rank", "actual", "log", "resid", "linear", "resid")
    result.expected_points_by_rank.each_with_index do |actual, index|
      rank = index + 1
      log_v = log_fit.expected_points_for(rank, result.team_count)
      lin_v = linear_fit.expected_points_for(rank, result.team_count)
      puts format("%-6d %-9.2f %-9.2f %-+9.2f %-9.2f %+.2f", rank, actual, log_v, actual - log_v, lin_v, actual - lin_v)
    end
    puts
    puts "Log fit:    #{log_fit.formula(result.team_count)}  (r² #{log_fit.r_squared} · rmse #{log_fit.rmse})"
    puts "Linear fit: #{linear_fit.formula(result.team_count)}  (r² #{linear_fit.r_squared} · rmse #{linear_fit.rmse})"
    puts "Best: #{result.best_fit.kind}  (World Cup goals curve: 0.2 + 4.3 * ln(n/rank)/ln(n))"
  end

  desc "Build a preseason TESTING slate + free contest (YEAR=2026 WEEK=4) — a live feed with no money on it"
  task preseason_slate: :environment do
    year = Integer(ENV.fetch("YEAR", Date.current.year))
    week = Integer(ENV.fetch("WEEK", 4))

    result = Nfl::BuildPreseasonSlate.call(year: year, week: week)

    puts "slate:    #{result.slate.name}"
    puts "games:    #{result.games.length}"
    puts "matchups: #{result.matchups.length}"
    puts "contest:  #{result.contest ? "#{result.contest.name} (free, #{result.contest.status})" : "none"}"
    puts
    puts "Populate it with real scores:  bin/nfl-live-poll --slot #{year}:1:#{week}"
  rescue Nfl::BuildPreseasonSlate::Error => e
    abort "preseason slate: #{e.message}"
  end

  desc "Recolor existing NFL teams from Nfl::TeamPalette (post-deploy: colors only, never games/slates)"
  task recolor: :environment do
    count = Nfl::TeamPalette.apply!
    puts "nfl:recolor — recolored #{count} team(s) from Nfl::TeamPalette::PALETTE"
  end
end

# NFL player database — Person + Athlete seeded from nflverse, with headshots
# cached to S3 via studio-engine's ImageCache. See
# app/services/nflverse/seed_players.rb.
namespace :nfl do
  desc "Seed Person + Athlete from nflverse players.csv. MIN_SEASON=2026 STATUS=ACT SKIP_HEADSHOTS=1 VERBOSE=1"
  task players_seed: :environment do
    seeder = Nflverse::SeedPlayers.new(
      verbose:          ENV["VERBOSE"].present?,
      upload_headshots: ENV["SKIP_HEADSHOTS"].blank?,
      min_season:       ENV.fetch("MIN_SEASON", Nflverse::SeedPlayers::DEFAULT_MIN_SEASON),
      status_filter:    ENV.fetch("STATUS", "ACT")
    )
    seeder.call

    puts
    puts "people:   #{Person.count}"
    puts "athletes: #{Athlete.count} (#{Athlete.on_a_team.count} on a roster)"
    puts "headshots: #{ImageCache.where(owner_type: 'Athlete', purpose: 'headshot').count} variants cached"
  end

  desc "Cache headshot variants for Athletes that have an espn_id but no cached image. Idempotent."
  task upload_headshots: :environment do
    widths = Nflverse::SeedPlayers::HEADSHOT_WIDTHS
    candidates = Athlete.where.not(espn_id: nil).includes(:image_caches)
    puts "candidates: #{candidates.count} athletes; widths: #{widths.inspect}"

    cached = skipped = failed = 0

    candidates.find_each do |athlete|
      have = athlete.image_caches.select { |c| c.purpose == "headshot" }.map(&:variant)
      if (["original", *widths.map(&:to_s)] - have).empty?
        skipped += 1
        next
      end

      folder = athlete.team_slug.presence || "free-agents"
      begin
        Studio::ImageCache.cache!(
          owner: athlete,
          purpose: "headshot",
          source_url: athlete.espn_headshot_url,
          key_prefix: "headshots/nfl/#{folder}/#{athlete.person_slug}",
          widths: widths,
          content_type: "image/png"
        )
        cached += 1
        puts "  [+] #{athlete.person_slug}" if cached <= 5 || (cached % 100).zero?
      rescue StandardError => e
        failed += 1
        puts "  [!] #{athlete.person_slug}: #{e.class}: #{e.message}"
      end
    end

    puts
    puts "cached:  #{cached}"
    puts "skipped: #{skipped} (already complete)"
    puts "failed:  #{failed}"
  end
end
