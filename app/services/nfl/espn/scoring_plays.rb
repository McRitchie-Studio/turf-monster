module Nfl
  module Espn
    # Pure parse seam: an ESPN summary payload -> one row per scoring play.
    #
    # The important decision in this file is that POINTS ARE DERIVED FROM THE
    # RUNNING SCORE, never from the play's type. ESPN folds the try into the
    # touchdown that earned it, so a single play row abbreviated "TD" is worth:
    #
    #   7  touchdown + successful extra point   (14 of 33 sampled plays)
    #   6  touchdown, extra point missed        ( 3 of 33)
    #   8  touchdown + two-point conversion     ( 2 of 33)
    #
    # Reading 6 off the "TD" label would therefore under-score most touchdowns
    # by a point and every two-point conversion by two. The `homeScore` /
    # `awayScore` that ESPN stamps on each play are the score AFTER it, so the
    # difference against the previous play is exactly what the play was worth —
    # and it stays correct for scoring types this code has never seen.
    #
    # The type abbreviation still matters, but only for the toast's LABEL.
    module ScoringPlays
      # ESPN abbreviation -> our scoring_type. Safety is included on both of the
      # spellings ESPN has been observed to use; it is rare enough that no
      # sampled game contained one, so POINTS_TO_TYPE below is the real
      # backstop rather than this table.
      ABBREVIATION_TO_TYPE = {
        "TD"  => "touchdown",
        "FG"  => "field_goal",
        "SF"  => "safety",
        "SAF" => "safety",
        "PAT" => "pat",
        "EP"  => "pat"
      }.freeze

      # Fallback when the abbreviation is missing or unrecognised. Keyed on what
      # the play was actually worth, which we always know.
      POINTS_TO_TYPE = {
        8 => "touchdown", 7 => "touchdown", 6 => "touchdown",
        3 => "field_goal", 2 => "safety", 1 => "pat"
      }.freeze

      # `scorer` is the player ESPN names at the FRONT of the play text — the
      # receiver on a pass, the rusher on a rush, the returner on a defensive
      # score, the kicker on a field goal. Derived here rather than at the call
      # site so the parse stays with the rest of the payload reading, and nil
      # when the text names nobody we can trust. See Nfl::Espn::Scorer.
      Row = Data.define(
        :external_id, :team_abbr, :scoring_type, :points, :period, :clock, :text,
        :scorer, :description
      )

      # `home_abbr` / `away_abbr` come from the scoreboard row for the same
      # game. They are what lets a play's team decide WHICH running total to
      # difference — the alternative, taking whichever side moved, misreads a
      # safety, where the points go to the team that did not have the ball.
      # DID THE PAYLOAD REPORT A PLAY LIST AT ALL?
      #
      # `(payload["scoringPlays"] || [])` cannot tell "this game has no scoring
      # plays yet" from "this response does not contain the key" — and a
      # degraded 200 with valid JSON and no key therefore parsed to zero plays
      # and drove the caller's reconciliation loop to delete every goal it held.
      # Measured: goals 3 -> 0, score 10-7 -> 0-0, silently.
      #
      # An Array — even an empty one — is a real answer. Anything else is the
      # feed declining to tell us, and the caller must refuse to act on it.
      def self.reported?(payload)
        payload.is_a?(Hash) && payload["scoringPlays"].is_a?(Array)
      end

      def self.rows_from(payload, home_abbr:, away_abbr:)
        previous_home = 0
        previous_away = 0

        (payload["scoringPlays"] || []).filter_map do |play|
          home_total = play["homeScore"].to_i
          away_total = play["awayScore"].to_i
          team_abbr  = play.dig("team", "abbreviation")

          points =
            case team_abbr
            when home_abbr then home_total - previous_home
            when away_abbr then away_total - previous_away
            end

          previous_home = home_total
          previous_away = away_total

          # A play crediting neither competitor, or crediting one with no
          # points, is not something we can score. Skipping beats guessing.
          next if points.nil? || points <= 0

          # AN ID-LESS PLAY CANNOT BE RECONCILED, and storing one is worse than
          # dropping it: `play["id"].to_s` yields "" rather than NULL, and the
          # unique index's `WHERE external_id IS NOT NULL` predicate COVERS "".
          # So the second id-less play anywhere in the league collides with the
          # first — across games — raising PG::UniqueViolation mid-cycle.
          next if play["id"].to_s.strip.empty?

          Row.new(
            external_id:  play["id"].to_s,
            team_abbr:    team_abbr,
            scoring_type: type_for(play, points),
            points:       points,
            period:       play.dig("period", "number"),
            clock:        play.dig("clock", "displayValue"),
            text:         play["text"].to_s.strip,
            scorer:       Scorer.from(play["text"]),
            description:  PlayDescription.from(play["text"], type_for(play, points))
          )
        end
      end

      def self.type_for(play, points)
        abbreviation = play.dig("type", "abbreviation") ||
                       play.dig("scoringType", "abbreviation")

        ABBREVIATION_TO_TYPE[abbreviation.to_s.upcase] ||
          POINTS_TO_TYPE.fetch(points, "touchdown")
      end
    end
  end
end
