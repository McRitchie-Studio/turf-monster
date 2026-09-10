module Nfl
  module Espn
    # Resolves an ESPN team abbreviation to a Team row.
    #
    # `Team#short_name` already holds the NFL abbreviation — it is the key
    # `Nfl::TeamPalette.apply!` matches on to recolor the league — and diffing
    # ESPN's 32 abbreviations against our palette shows 31 of them agreeing
    # exactly. So this is almost a no-op lookup, and the whole reason the file
    # exists is the thirty-second:
    #
    #   ESPN calls Washington "WSH". We call them "WAS".
    #
    # Without the alias, every Washington score would resolve to nil and be
    # skipped — not loudly, but as a team that simply never scores. A silent
    # per-team blind spot in a feed that settles contests is the worst failure
    # mode available here, which is why the alias table is a first-class,
    # tested object rather than an inline `||`.
    module TeamMap
      ALIASES = { "WSH" => "WAS" }.freeze

      def self.team_for(abbreviation)
        slug_key = ALIASES.fetch(abbreviation.to_s, abbreviation.to_s)
        return nil if slug_key.empty?

        Team.nfl.find_by(short_name: slug_key)
      end

      # The abbreviation we store teams under, for a given ESPN abbreviation.
      def self.canonical(abbreviation)
        ALIASES.fetch(abbreviation.to_s, abbreviation.to_s)
      end
    end
  end
end
