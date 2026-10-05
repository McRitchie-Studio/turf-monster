module Nfl
  module Espn
    # Pure parse seam: ESPN play records -> one row per play, scoring or not.
    #
    # Sibling to ScoringPlays, and deliberately separate from it. That module
    # decides what a play was WORTH and contests are paid on its answer; this
    # one only says what happened, for a reader watching the board. Nothing
    # here can move a score.
    #
    # TWO SOURCES, ONE ROW SHAPE.
    #
    #   the scoreboard's `situation.lastPlay`  — the single most recent play of
    #       every live game, inside the one request a cycle already makes. Free,
    #       but it carries no clock and no down of its own, and a second play
    #       inside one polling interval is never seen.
    #   the summary's `drives`                 — every play of ONE game, with its
    #       quarter, clock and down. ~600 KB, so it is spent sparingly: see
    #       LiveScores::PollCycle#sync_plays.
    #
    # Both are keyed on the same ESPN play id, so a play first seen on the
    # scoreboard is the same row the summary later fills in.
    module Plays
      Row = Data.define(
        :external_id, :play_type, :kind, :text, :team_abbr,
        :period, :clock, :down_distance, :yards, :home_score, :away_score,
        # Did this play move the chains? nil when the source cannot say — the
        # caller must then leave whatever it already holds alone.
        :first_down
      )

      # What a play IS to someone glancing at the feed. The board marks these
      # differently, so the vocabulary is small and closed; anything ESPN
      # invents next season falls through to "play" and still renders.
      #
      # ORDER MATTERS: "Official Timeout" must reach `break` before the bare
      # "Timeout" pattern claims it — only a team's own timeout costs it one of
      # its three, and that is the one a reader is counting.
      KIND_PATTERNS = [
        [/official timeout|two-minute warning|end (of )?(period|quarter|half|game|regulation)|coin toss/i, "break"],
        [/timeout/i,                                    "timeout"],
        [/touchdown|field goal good|safety|two-point.*(good|success)|extra point good/i, "score"],
        [/intercept|fumble recovery \(opponent\)|turnover on downs|blocked .*(recover|return)/i, "turnover"],
        [/penalty/i,                                    "penalty"],
        [/sack/i,                                       "sack"],
        [/punt|kickoff|field goal|extra point/i,        "kick"]
      ].freeze

      KINDS = (KIND_PATTERNS.map(&:last) + ["play"]).uniq.freeze

      # DID THE SUMMARY CARRY A PLAY LIST AT ALL? Same question, and the same
      # reason, as ScoringPlays.reported?: a degraded 200 with no `drives` key
      # must read as "the feed declined to answer", never as "no plays".
      def self.reported?(payload)
        payload.is_a?(Hash) && payload["drives"].is_a?(Hash)
      end

      # Every play of one game, oldest first, from a summary payload.
      #
      # `drives.current` REPEATS the last drive of `drives.previous` while that
      # drive is still going, so plays are de-duplicated on their id — the later
      # copy wins, because it is the one ESPN is still editing.
      def self.rows_from(payload)
        return [] unless reported?(payload)

        drives = Array(payload.dig("drives", "previous")) + [payload.dig("drives", "current")].compact
        teams = team_abbreviations(drives)

        rows = {}
        drives.each do |drive|
          Array(drive["plays"]).each do |play|
            row = row_from(play, team_abbr: teams[play.dig("start", "team", "id").to_s] ||
                                            drive.dig("team", "abbreviation"))
            rows[row.external_id] = row if row
          end
        end
        rows.values
      end

      # The scoreboard's lastPlay for one game. `competitors` resolves the
      # team id, and `period` / `clock` are the game's own — the scoreboard
      # stamps neither on the play, and where the clock stands now is the best
      # available answer for a play that has just ended.
      def self.row_from_last_play(situation, competitors:, period: nil, clock: nil)
        play = situation.is_a?(Hash) ? situation["lastPlay"] : nil
        return nil unless play.is_a?(Hash)

        id = play.dig("team", "id").to_s
        holder = Array(competitors).find { |competitor| competitor["id"].to_s == id }

        row = row_from(play, team_abbr: holder&.dig("team", "abbreviation"), period: period, clock: clock)
        row&.with(first_down: first_down_from_situation?(row, play, situation))
      end

      # THE SCOREBOARD'S GUESS AT A FIRST DOWN. Its copy of a play has no down
      # before or after, so the only evidence is the situation the play left
      # behind: the same team still has the ball, it is first down, and the
      # play was an ordinary snap that gained ground. A new drive cannot fool
      # it — the play before a drive's first snap is a kick or a turnover, never
      # an ordinary snap by the team now holding the ball. The summary's copy,
      # when it arrives, overrules this with the real before-and-after.
      def self.first_down_from_situation?(row, play, situation)
        row.kind == "play" &&
          situation["down"].to_i == 1 &&
          play["statYardage"].to_i.positive? &&
          situation["possession"].to_s == play.dig("team", "id").to_s &&
          situation["possession"].to_s.present?
      end

      def self.row_from(play, team_abbr: nil, period: nil, clock: nil)
        # An id-less play cannot be reconciled against the next cycle's copy of
        # itself, so it would be re-inserted forever. Skipping beats guessing.
        id = play["id"].to_s.strip
        return nil if id.empty?

        type = play.dig("type", "text").to_s.strip
        text = play["text"].to_s.squish
        return nil if type.empty? && text.empty?

        kind = kind_for(type, play)

        Row.new(
          external_id:   id,
          play_type:     type.presence,
          kind:          kind,
          text:          text.presence || type,
          team_abbr:     team_abbr,
          period:        play.dig("period", "number") || period,
          clock:         play.dig("clock", "displayValue").presence || clock,
          down_distance: play.dig("start", "downDistanceText").presence,
          yards:         play["statYardage"],
          home_score:    play["homeScore"],
          away_score:    play["awayScore"],
          first_down:    first_down?(play, kind)
        )
      end

      # MOVED THE CHAINS: an ordinary snap that started on some down with a
      # distance to make, made it, and left the SAME team on first down. Read
      # from the play's own before-and-after, which only the summary carries —
      # nil without them, so "cannot say" never reads as "did not".
      #
      # Ordinary snaps only. A touchdown is a score, an interception return is
      # a turnover, and a penalty that hands over a first down moved nobody.
      def self.first_down?(play, kind)
        start = play["start"]
        finish = play["end"]
        return nil unless start.is_a?(Hash) && finish.is_a?(Hash) && start.key?("down") && finish.key?("down")
        return false unless kind == "play"

        start["down"].to_i.positive? && start["distance"].to_i.positive? &&
          finish["down"].to_i == 1 &&
          start.dig("team", "id").to_s == finish.dig("team", "id").to_s &&
          play["statYardage"].to_i >= start["distance"].to_i
      end

      # The flags outrank the type's wording where ESPN sets them: a pass that
      # ends in a touchdown is typed "Passing Touchdown", but a fumble returned
      # for one is typed by the fumble and only `scoringPlay` says it scored.
      def self.kind_for(type, play)
        named = KIND_PATTERNS.find { |pattern, _| type.match?(pattern) }&.last
        return named if %w[break timeout].include?(named)
        return "score"    if play["scoringPlay"] == true
        return "turnover" if play["isTurnover"] == true
        return "penalty"  if play["isPenalty"] == true

        named || "play"
      end

      def self.team_abbreviations(drives)
        drives.each_with_object({}) do |drive, map|
          id = drive.dig("team", "id").to_s
          abbreviation = drive.dig("team", "abbreviation")
          map[id] = abbreviation if id.present? && abbreviation.present?
        end
      end
      private_class_method :team_abbreviations
    end
  end
end
