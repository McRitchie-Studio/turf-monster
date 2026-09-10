namespace :slates do
  desc "Recompute stored turf scores from each slate's sport curve (ranks preserved)"
  task recompute_turf_scores: :environment do
    Slate.where.not(name: "Default").find_each do |slate|
      n = slate.slate_matchups.distinct.count(:team_slug)
      next if n.zero?

      updated = 0
      slate.slate_matchups.where.not(rank: nil).find_each do |matchup|
        matchup.update!(turf_score: SlateMatchup.turf_score_for(matchup.rank, n, sport: slate.sport))
        updated += 1
      end
      puts "#{slate.slug || slate.name}: #{updated} matchups recomputed (#{slate.sport}, n=#{n})"
    end
  end
end
