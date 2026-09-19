module Nfl
  module Espn
    # Pure parse seam: an ESPN scoreboard payload -> one MARKET row per game.
    #
    # ESPN carries DraftKings' OWN lines (`odds[].provider.name == "DraftKings"`),
    # and that is the whole reason this exists: DK's own sportsbook refuses this
    # network outright — Akamai 403 on every URL shape, headless browser
    # included — so the scraper the market-snapshot SOP calls 🔨 PLANNED for the
    # NFL could not be wired against DK directly even if someone tried.
    #
    # ESPN publishes the PRIMITIVES only: a game total and a spread, never a
    # team total. So every row here is basis "derived"
    # (`Nfl::CacheExpectedTeamTotals.derive` does that arithmetic). NEVER stamp
    # "posted" from this source — posted means DK listed that team's own O/U.
    #
    # Total by design, like Nfl::Espn::Scoreboard: a payload with no events
    # parses to [], and a game whose odds are missing or unreadable comes back
    # as an INCOMPLETE row rather than an exception. Deciding what a gap means
    # belongs to the caller, which refuses the week — see
    # Nfl::FetchMarketLines.
    module MarketLines
      PROVIDER = "DraftKings".freeze

      # DK writes a pick'em as "EVEN" (and some feeds as "PK"), with no
      # favorite flagged on either side. That is a real, complete line — spread
      # zero — not a gap, and reading it as one would drop the game.
      PICK_EM = /\A\s*(even|pk|pick)\s*\z/i

      # "PIT -2.5" — the abbreviation is the FAVORITE. Used only when the
      # favorite booleans are absent; the booleans are the primary source.
      DETAIL_FAVORITE = /\A\s*([A-Z]{2,4})\s+([-+]?\d+(?:\.\d+)?)/

      Row = Data.define(:week, :away_abbr, :home_abbr, :favorite_abbr,
                        :favorite_spread, :game_total, :detail) do
        # A row carrying everything Nfl::CacheExpectedTeamTotals.derive needs.
        def complete?
          favorite_abbr.present? && !favorite_spread.nil? && !game_total.nil?
        end

        def matchup
          "#{away_abbr} at #{home_abbr}"
        end
      end

      def self.rows_from(payload)
        (payload["events"] || []).filter_map { |event| row_from(event) }
      end

      def self.row_from(event)
        competition = (event["competitions"] || []).first
        return nil unless competition

        competitors = competition["competitors"] || []
        home = competitors.find { |c| c["homeAway"] == "home" }
        away = competitors.find { |c| c["homeAway"] == "away" }
        return nil unless home && away

        odds = dk_odds(competition)
        favorite, spread = favorite_and_spread(odds, home, away)

        Row.new(
          week: event.dig("week", "number"),
          away_abbr: away.dig("team", "abbreviation"),
          home_abbr: home.dig("team", "abbreviation"),
          favorite_abbr: favorite,
          favorite_spread: spread,
          game_total: numeric(odds["overUnder"]),
          detail: odds["details"]
        )
      end

      # DraftKings or nothing. ESPN lists several books on some games, and
      # silently taking odds[0] would mix providers row to row — the dataset
      # records ONE book by name, and a mixed one is not that.
      def self.dk_odds(competition)
        (competition["odds"] || []).find { |o| o.dig("provider", "name") == PROVIDER } || {}
      end

      # Who is favored, and by how much — as a NEGATIVE number, the sign
      # convention the seed CSV and Nfl::CacheExpectedTeamTotals#home_spread_for
      # share: the favorite's spread is negative.
      #
      # The booleans are primary and the `details` string is the fallback. ESPN
      # sends `spread` as the HOME team's line (negative when home is favored),
      # so its magnitude is the same either way and only the side differs.
      def self.favorite_and_spread(odds, home, away)
        return [home.dig("team", "abbreviation"), 0.0] if PICK_EM.match?(odds["details"].to_s)

        magnitude = numeric(odds["spread"])&.abs
        abbr = if odds.dig("homeTeamOdds", "favorite")
          home.dig("team", "abbreviation")
        elsif odds.dig("awayTeamOdds", "favorite")
          away.dig("team", "abbreviation")
        else
          detail_favorite(odds["details"])
        end

        magnitude ||= detail_spread(odds["details"])
        return [nil, nil] if abbr.nil? || magnitude.nil?

        [abbr, -magnitude.abs]
      end

      def self.detail_favorite(details)
        DETAIL_FAVORITE.match(details.to_s)&.captures&.first
      end

      def self.detail_spread(details)
        DETAIL_FAVORITE.match(details.to_s)&.captures&.last&.to_f
      end

      # Numeric or nil — never 0.0 for a missing line. `"".to_f` is 0.0, and a
      # zero total or spread is a real value here (a pick'em is spread 0), so a
      # blank must stay nil or a gap would read as a genuine pick'em.
      def self.numeric(value)
        return nil if value.nil? || value.to_s.strip.empty?

        Float(value)
      rescue ArgumentError, TypeError
        nil
      end
    end
  end
end
