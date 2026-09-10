module Admin
  module SlatesHelper
    def game_card_data(game)
      home = game.home_team
      away = game.away_team
      matchups = SlateMatchup.where(game_slug: game.slug)

      {
        slug: game.slug,
        status: game.status,
        homeScore: game.home_score || 0,
        awayScore: game.away_score || 0,
        home: {
          slug: home.slug,
          name: home.name,
          shortName: home.short_name,
          emoji: home.emoji,
          expectedScore: matchups.find { |m| m.team_slug == home.slug }&.expected_score,
          turfScore: matchups.find { |m| m.team_slug == home.slug }&.turf_score&.to_f,
          players: home.players.order(:name).map { |p| { slug: p.slug, name: p.name, position: p.position, number: p.jersey_number } }
        },
        away: {
          slug: away.slug,
          name: away.name,
          shortName: away.short_name,
          emoji: away.emoji,
          expectedScore: matchups.find { |m| m.team_slug == away.slug }&.expected_score,
          turfScore: matchups.find { |m| m.team_slug == away.slug }&.turf_score&.to_f,
          players: away.players.order(:name).map { |p| { slug: p.slug, name: p.name, position: p.position, number: p.jersey_number } }
        },
        goals: game.goals.order(:created_at).map { |g|
          {
            id: g.id,
            teamSlug: g.team_slug,
            playerSlug: g.player_slug,
            playerName: g.player&.name,
            teamEmoji: g.team&.emoji,
            minute: g.minute
          }
        },
        kickoffAt: game.kickoff_at&.iso8601
      }.to_json
    end
  end
end
