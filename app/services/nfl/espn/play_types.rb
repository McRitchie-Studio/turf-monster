module Nfl
  module Espn
    # WHAT AN ESPN PLAY TYPE IS — the one table both readers of a play use.
    #
    # Two questions are asked of every play, and they used to be answered by
    # two tables that had to agree and did not:
    #
    #   kind    — how the feed MARKS it (Plays.kind_for, stored on GamePlay):
    #             score, turnover, penalty, timeout, break, sack, kick, play.
    #   result  — what the play-by-play bar CALLS it (GamePlay#result_label):
    #             "Interception", "Missed Field Goal", "Two-Point Try".
    #
    # The two-point try showed what two tables cost: ESPN writes "Two-Point
    # Conversion" and also "Two Point Rush", and BOTH lists matched only the
    # hyphen, so "Two Point Rush" was a Rush to one and nothing to the other.
    # One row per type now carries both answers.
    #
    # FIRST MATCH WINS, so the specific rows sit above the general ones they
    # contain: "Official Timeout" above "Timeout", "Field Goal Good" above
    # "Field Goal", the try above "Touchdown" (a touchdown's text often goes on
    # to describe its extra point). Anything ESPN invents next season matches
    # nothing: its kind is "play" and its result falls back to the caller.
    module PlayTypes
      Type = Data.define(:pattern, :result, :kind)

      TWO_POINT = /two[- ]?point|2pt/i

      TABLE = [
        # Breaks in play belong to nobody.
        [/official timeout/i,                               "Official Timeout",   "break"],
        [/two-minute warning/i,                             "Two-Minute Warning", "break"],
        [/end of half/i,                                    "Halftime",           "break"],
        [/end of (game|regulation)/i,                       "End of Game",        "break"],
        [/end (of )?(period|quarter)/i,                     "End of Quarter",     "break"],
        [/coin toss/i,                                      "Coin Toss",          "break"],
        # A team's own timeout — the one a reader is counting.
        [/timeout/i,                                        "Timeout",            "timeout"],
        # The try after a touchdown, made or missed.
        [/extra point good/i,                               "Extra Point",        "score"],
        [/extra point|\bpat\b/i,                            "Extra Point",        "kick"],
        [/(?:#{TWO_POINT.source}).*(good|success)/i,           "Two-Point Try",      "score"],
        [TWO_POINT,                                         "Two-Point Try",      "play"],
        # Points.
        [/touchdown/i,                                      "Touchdown",          "score"],
        [/safety/i,                                         "Safety",             "score"],
        [/field goal good/i,                                "Field Goal",         "score"],
        # The ball changing hands.
        [/intercept/i,                                      "Interception",       "turnover"],
        [/fumble recovery \(opponent\)/i,                   "Fumble Recovered",   "turnover"],
        [/turnover on downs/i,                              "Turnover on Downs",  "turnover"],
        [/blocked field goal.*(recover|return)/i,           "Blocked Field Goal", "turnover"],
        [/blocked punt.*(recover|return)/i,                 "Blocked Punt",       "turnover"],
        [/fumble/i,                                         "Fumble",             "play"],
        # Kicks.
        [/blocked field goal/i,                             "Blocked Field Goal", "kick"],
        [/blocked punt/i,                                   "Blocked Punt",       "kick"],
        [/field goal/i,                                     "Missed Field Goal",  "kick"],
        [/punt/i,                                           "Punt",               "kick"],
        [/kickoff/i,                                        "Kickoff",            "kick"],
        # Everything else a snap can be.
        [/penalty/i,                                        "Penalty",            "penalty"],
        [/sack/i,                                           "Sack",               "sack"],
        [/incompletion|incomplete/i,                        "Incompletion",       "play"],
        [/pass reception|completion/i,                      "Completion",         "play"],
        [/rush/i,                                           "Rush",               "play"]
      ].map { |pattern, result, kind| Type.new(pattern: pattern, result: result, kind: kind) }.freeze

      KINDS = (TABLE.map(&:kind) + ["play"]).uniq.freeze

      # The row for a type (or any text), or nil when nothing matches.
      def self.classify(text)
        source = text.to_s
        return nil if source.strip.empty?

        TABLE.find { |type| source.match?(type.pattern) }
      end
    end
  end
end
