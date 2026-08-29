module Nfl
  module Espn
    # WHAT HAPPENED, in words — the line under the scorer's name on the focus
    # card. A pure parse seam over the same play text Nfl::Espn::Scorer reads.
    #
    #   "Josh Oliver 12 Yd pass from Carson Wentz (Will Reichard Kick)"
    #     -> "12 yard receiving TD"
    #   "Jordan Mason 5 Yd Rush (Will Reichard Kick)"
    #     -> "5 yard rushing TD"
    #   "Will Reichard 35 Yd Field Goal"
    #     -> "35 yard field goal"
    #   "Isaiah Rodgers 87 Yd Interception Return (Will Reichard Kick)"
    #     -> "Defensive touchdown"
    #   "Kaevon Merriweather Safety"
    #     -> "Safety"
    #
    # THE DEFENSIVE SCORES COLLAPSE ON PURPOSE. An interception return, a fumble
    # recovery and a blocked-punt return are three different plays and one
    # thing to a reader glancing at a live card — and spelling each out costs a
    # line of width the card does not have. The yardage goes with them, because
    # "87 yard interception return TD" is the longest string this line can
    # produce and it is the one nobody needs.
    module PlayDescription
      YARDS = /(\d+)\s*[Yy]d\.?/

      def self.from(text, scoring_type = nil)
        line = text.to_s.strip
        return nil if line.empty?

        yards = line[YARDS, 1]

        case line
        when /\bpass\s+from\b/i      then yards && "#{yards} yard receiving TD"
        # ESPN writes BOTH "Rush" and "Run" for the same play — measured across
        # 235 real scoring lines, 45 said Rush and 6 said Run. Matching only one
        # of them silently dropped the description on every Josh Jacobs score.
        when /\b(?:Rush|Run)\b/i     then yards && "#{yards} yard rushing TD"
        when /\bField\s+Goal\b/i     then yards && "#{yards} yard field goal"
        when /\bSafety\b/i           then "Safety"
        when /\bDefensive\s+PAT\b/i  then "Defensive conversion"
        when /\b(Interception|Fumble|blocked punt|Kickoff|Punt)\b.*\bReturn\b/i,
             /\bReturn\b.*\b(Interception|Fumble|blocked punt)\b/i,
             /\bFumble\s+Recovery\b/i,
             /\breturn of blocked punt\b/i
          "Defensive touchdown"
        else
          # An unrecognised shape still says something true if we know the type.
          fallback_for(scoring_type)
        end
      end

      def self.fallback_for(scoring_type)
        case scoring_type.to_s
        when "touchdown"  then "Touchdown"
        when "field_goal" then "Field goal"
        when "safety"     then "Safety"
        when "two_point"  then "Two-point conversion"
        when "pat"        then "Extra point"
        end
      end
      private_class_method :fallback_for
    end
  end
end
