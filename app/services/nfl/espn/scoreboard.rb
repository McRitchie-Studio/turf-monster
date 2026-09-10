module Nfl
  module Espn
    # Pure parse seam: an ESPN scoreboard payload -> one row per game.
    #
    # Total by design. A payload with no events parses to [], a game missing a
    # competitor is skipped rather than raised on, and nothing here touches the
    # database or the network. Everything that decides what an empty parse MEANS
    # lives in the caller.
    module Scoreboard
      # ESPN's `status.type.state` vocabulary mapped onto `games.status`.
      # "post" is deliberately absent: a postponed game is also state "post",
      # and only the `completed` flag separates it from a finished one.
      STATE_TO_STATUS = { "pre" => "scheduled", "in" => "in_progress" }.freeze

      Row = Data.define(
        :external_id, :season_year, :season_type, :week, :kickoff_at, :status,
        :home_abbr, :home_score, :away_abbr, :away_score,
        :period, :clock, :detail,
        # THE SITUATION — down, distance, and who has the ball where. Present
        # only while a game is actually being played: ESPN omits the block
        # before kickoff and after the final whistle, and these three then
        # parse to nil, which is what the caller writes through.
        :down_distance, :possession_text, :possession_abbr
      )

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

        status = competition["status"] || {}
        type = status["type"] || {}
        situation = competition["situation"] || {}

        Row.new(
          external_id: event["id"].to_s,
          season_year: event.dig("season", "year"),
          season_type: event.dig("season", "type"),
          week:        event.dig("week", "number"),
          kickoff_at:  parse_time(event["date"]),
          status:      status_from(type),
          home_abbr:   home.dig("team", "abbreviation"),
          home_score:  score_from(home),
          away_abbr:   away.dig("team", "abbreviation"),
          away_score:  score_from(away),
          period:      status["period"],
          clock:       status["displayClock"],
          detail:      type["shortDetail"],
          down_distance:   text_from(situation["downDistanceText"]),
          possession_text: text_from(situation["possessionText"]),
          possession_abbr: possession_abbr_from(situation, competitors)
        )
      end

      # ESPN sends a missing situation field as absent, and a cleared one as the
      # EMPTY STRING — "" is what arrives between the whistle and the next snap.
      # Both mean "no situation", and only nil says so to a nullable column: a
      # blank string is a value, and it would render as an empty line in the
      # rail rather than collapsing the row.
      def self.text_from(value)
        return nil if value.nil?

        stripped = value.to_s.strip
        stripped.empty? ? nil : stripped
      end

      # WHO HAS THE BALL, as a team ABBREVIATION rather than ESPN's competitor
      # id. `situation.possession` is that id, and the only place it can be
      # resolved is the competitor list on the same competition — so it is
      # resolved HERE, while both are in hand, rather than storing an opaque
      # number the caller would have to come back for.
      #
      # Compared as strings on purpose. ESPN sends the possession id as a string
      # ("17") and competitor ids as strings too, but the two have disagreed on
      # type across payload versions, and `17 == "17"` is false in Ruby.
      def self.possession_abbr_from(situation, competitors)
        id = text_from(situation["possession"])
        return nil unless id

        holder = competitors.find { |c| c["id"].to_s == id }
        holder&.dig("team", "abbreviation")
      end

      # A finished game and a POSTPONED game are both state "post"; only
      # `completed` tells them apart. Treating the postponed one as completed
      # would settle contests on a game that has not been played.
      def self.status_from(type)
        return "completed" if type["completed"]

        STATE_TO_STATUS.fetch(type["state"], "scheduled")
      end

      # ESPN sends scores as strings ("20"), and sends "" before kickoff.
      #
      # RETURNS nil, NOT 0, when the score is missing — the two mean different
      # things and collapsing them is what made a corrupted board look healthy.
      # A blank score before kickoff is genuinely 0-0; a blank score on a game
      # ESPN says is IN PROGRESS is a degraded response. Reporting both as 0 let
      # `detect_drift` compare our wiped 0-0 against the feed's blank-parsed 0-0,
      # agree, and emit no anomaly while the scores were being destroyed.
      #
      # Deciding which case this is needs the game's status, which the caller
      # has and this method does not. So it reports honestly and the caller
      # decides — see PollCycle#scores_known?.
      def self.score_from(competitor)
        value = competitor["score"]
        return nil if value.nil? || value.to_s.strip.empty?

        Integer(value)
      rescue ArgumentError, TypeError
        nil
      end

      def self.parse_time(value)
        return nil if value.blank?

        Time.zone.parse(value.to_s)
      end
    end
  end
end
