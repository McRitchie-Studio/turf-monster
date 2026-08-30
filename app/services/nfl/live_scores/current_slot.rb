module Nfl
  module LiveScores
    # Which week the /live scoreboard should show when nobody said.
    #
    # Answered from OUR database, never from the network — the page must render
    # instantly and must still render when ESPN is unreachable. The poller is
    # what keeps the data behind these questions fresh.
    #
    # The order encodes what a visitor means by "live":
    #   1. a game actually in progress          — the literal answer
    #   2. a game that kicked off recently      — just-finished slates still
    #                                             read as "today's games"
    #   3. the next game scheduled              — pregame Sunday morning
    #   4. the most recent game we know of      — the off-season fallback
    module CurrentSlot
      # How long a finished slate keeps owning the page. Long enough to cover a
      # full Sunday (first kickoff to the last whistle is about ten hours), so
      # the board does not jump to next week while the night game is being
      # discussed.
      RECENT_WINDOW = 12.hours

      def self.call
        slot_for(in_progress || recently_started || next_scheduled || most_recent)
      end

      def self.games_for(slot)
        return Game.none unless slot

        # `:goals` is for the FOCUS PANEL, which renders every game as a hero
        # tile and each hero tile draws its own scoring-play rail. Without it
        # the one query behind this page becomes sixteen.
        Game.nfl.in_season_slot(**slot).includes(:home_team, :away_team, :goals)
      end

      def self.slot_for(game)
        return nil unless game

        { year: game.season_year, season_type: game.season_type, week: game.week }
      end

      # Two filters, both load-bearing.
      #
      # `.nfl` — this is the NFL scoreboard, and Game is shared with the World
      # Cup contests. Without it a soccer fixture carrying a season slot wins
      # the "most recent" lookup and the NFL board renders soccer, whose goals
      # then correctly refuse to broadcast to it. That is not hypothetical: it
      # is exactly what the e2e seed produced on the first run.
      #
      # `season_year` NOT NULL — every game predating the live feed has a null
      # slot, and a null slot cannot be rendered as a week.
      def self.scoped = Game.nfl.where.not(season_year: nil)

      def self.in_progress
        scoped.where(status: "in_progress").order(:kickoff_at).first
      end

      def self.recently_started
        scoped.where(kickoff_at: RECENT_WINDOW.ago..Time.current).order(kickoff_at: :desc).first
      end

      def self.next_scheduled
        scoped.where(kickoff_at: Time.current..).order(:kickoff_at).first
      end

      def self.most_recent
        scoped.order(kickoff_at: :desc).first
      end
    end
  end
end
