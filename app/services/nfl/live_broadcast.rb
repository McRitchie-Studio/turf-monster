module Nfl
  # Real-time broadcasts for the league-wide /live scoreboard (Turbo Streams
  # over ActionCable).
  #
  # Sibling to Contest::LiveBroadcast, not a replacement for it. That one
  # answers "how did this contest's leaderboard move?" and fans out to N
  # contests; this one answers "what is the score of every game right now?" and
  # fans out to exactly one page. A single scoring event legitimately feeds
  # both, which is why Goal carries a callback for each.
  #
  # Stream: "nfl_live". Targets:
  #   nfl_live_scoreboard   (update)  — the game grid for the affected slot
  #   nfl_live_event_feed   (append)  — a data-only node the page's
  #                                     MutationObserver turns into a toast
  #
  # Every broadcast is best-effort and individually rescued, matching
  # Contest::LiveBroadcast: a Redis hiccup must never fail the request that
  # recorded the score, nor stop its sibling broadcasts from going out.
  class LiveBroadcast
    STREAM = "nfl_live".freeze

    class << self
      # A scoring event landed. Toast it, then refresh the board.
      #
      # No-ops for anything that is not NFL. Goal fires this callback for every
      # row it writes, including World Cup goals, and a soccer goal has no
      # business appearing on the NFL scoreboard.
      def scoring_event(goal)
        game = goal.game
        return unless game && nfl?(goal.team)

        append_event(goal, game)
        replace_scoreboard(game)
      end

      # The score moved without a new scoring event (a play was overturned and
      # its Goal destroyed), or a game changed status.
      def score_changed(game, event: nil)
        return unless game && nfl?(game.home_team)

        append_final(game) if event == :game_completed
        replace_scoreboard(game)
      end

      # Games in the same season slot as the one that changed. This is what the
      # /live page renders, and re-rendering the whole slot (rather than the one
      # card) is what keeps a broadcast-replaced board identical to a freshly
      # loaded one.
      def slot_games(game)
        Game.nfl.in_season_slot(
          year: game.season_year, season_type: game.season_type, week: game.week
        ).includes(:home_team, :away_team)
      end

      private

      def nfl?(team)
        team&.league == "nfl"
      end

      def replace_scoreboard(game)
        Turbo::StreamsChannel.broadcast_update_to(
          STREAM,
          target:  "nfl_live_scoreboard",
          partial: "live/scoreboard",
          locals:  { games: slot_games(game) }
        )
      rescue => e
        ErrorLog.capture!(e)
      end

      def append_event(goal, game)
        Turbo::StreamsChannel.broadcast_append_to(
          STREAM,
          target:  "nfl_live_event_feed",
          partial: "live/event_feed_item",
          locals:  { event: "score", goal: goal, team: goal.team, game: game }
        )
      rescue => e
        ErrorLog.capture!(e)
      end

      def append_final(game)
        Turbo::StreamsChannel.broadcast_append_to(
          STREAM,
          target:  "nfl_live_event_feed",
          partial: "live/event_feed_item",
          locals:  { event: "final", goal: nil, team: nil, game: game }
        )
      rescue => e
        ErrorLog.capture!(e)
      end
    end
  end
end
