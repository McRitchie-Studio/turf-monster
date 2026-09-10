namespace :soccer do
  desc "Cache the checked-in 2026 World Cup DK team-total odds onto fifa-slate matchups"
  task team_total_odds_cache: :environment do
    path = ENV["DATA_PATH"].presence || Soccer::CacheTeamTotalOdds::DEFAULT_PATH
    result = Soccer::CacheTeamTotalOdds.call(path: path)
    puts "Cached DK team-total odds: #{result.rows} rows, #{result.matchups_updated} matchups updated" \
         "#{result.teams_missing.any? ? ", missing teams: #{result.teams_missing.join(', ')}" : ''}"
  end
end
