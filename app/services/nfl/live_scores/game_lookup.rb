module Nfl
  module LiveScores
    # THE ONE LOOKUP ORDER, so three callers cannot disagree about which Game a
    # scoreboard row is.
    #
    # `external_id` first, because it is collision-proof. Then the COMPUTED
    # slug, so a game the odds CSV already created is ADOPTED rather than
    # duplicated — without that second step the poller builds a parallel set of
    # games that no SlateMatchup points at, and scores update nothing.
    #
    # That second step is not a theoretical nicety: the 2026 week-2 games in
    # production were created by the slate build with no `external_id` at all,
    # so the slug is the ONLY handle that reaches them. Any caller asking "do we
    # already hold this game?" has to ask both questions in this order or it
    # will answer no about a row that exists.
    #
    # Extracted from PollCycle when SilentGapCheck became the third caller. A
    # copy of this order is the most dangerous kind of duplication here, because
    # a copy that drops the slug fallback still passes every test that uses
    # `external_id` and silently fails on exactly the production rows the
    # incident was about.
    module GameLookup
      # `home:`/`away:` let a caller that has already resolved both teams hand
      # them in rather than paying for the lookups a second time — the same
      # affordance #slug_for carries, and the reason a cycle can resolve its 32
      # abbreviations once. Behaviour is identical when they are omitted.
      def self.find(row, home: nil, away: nil)
        by_id = Game.find_by(external_id: row.external_id)
        return by_id if by_id

        slug = slug_for(row, home: home, away: away)
        return nil unless slug

        Game.find_by(slug: slug)
      end

      # The slug a row's game WOULD carry, which is what makes adoption
      # possible. `home:`/`away:` let a caller that has already resolved both
      # teams hand them in rather than paying for the lookups twice.
      def self.slug_for(row, home: nil, away: nil)
        home ||= Espn::TeamMap.team_for(row.home_abbr)
        away ||= Espn::TeamMap.team_for(row.away_abbr)
        return nil unless home && away

        Game.new(
          home_team_slug: home.slug, away_team_slug: away.slug,
          season_type: row.season_type, week: row.week
        ).name_slug
      end
    end
  end
end
