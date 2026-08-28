class Contest
  # Real-time broadcasts for the /contests/:id/live page (Turbo Streams over
  # ActionCable). Mirrors the chat broadcast pattern (Message#broadcast_new_message)
  # but from a service object, since goals fan out to N contests and the
  # leaderboard/games partials need locals the model callbacks can't set as ivars.
  #
  # All broadcasts are best-effort: a cable/Redis hiccup must never fail the
  # request that recorded the goal, nor block the sibling broadcasts — hence each
  # is individually rescued (same posture as Message#broadcast_new_message).
  #
  # Stream: [contest, :live]. Targets (update = inner HTML so the wrapper div +
  # its id survive every refresh and stay re-updatable):
  #   contest_<id>_leaderboard  (update)  — re-ranked leaderboard
  #   contest_<id>_games        (update)  — active/upcoming/completed games
  #   contest_<id>_goal_feed    (append)  — a data-only node the live page's
  #                                         MutationObserver turns into a toast
  class LiveBroadcast
    class << self
      # An admin recorded a goal. Toast everyone, then refresh leaderboard + games.
      def goal_scored(goal)
        game = goal.game
        return unless game

        affected_contests(game).each do |contest|
          append_goal_feed(contest, goal, game)
          replace_leaderboard(contest)
          replace_games(contest)
          replace_focus(contest)
        end
      end

      # Score changed without a new goal (goal removed) or a game was marked
      # final. Refresh leaderboard + games; on completion, a neutral FINAL toast.
      def score_changed(game, event: :goal_removed)
        return unless game

        affected_contests(game).each do |contest|
          append_final_feed(contest, game) if event == :game_completed
          replace_leaderboard(contest)
          replace_games(contest)
          replace_focus(contest)
        end
      end

      # Contests including this game's matchups that are live right now. Mirrors
      # Game#score_affected_contests! (status: open — a live contest is DB-open,
      # locked is derived) plus an explicit live? filter so we don't push to
      # not-yet-started or settled contests.
      def affected_contests(game)
        slate_ids = SlateMatchup.where(game_slug: game.slug).pluck(:slate_id).uniq
        return [] if slate_ids.empty?

        Contest.where(slate_id: slate_ids, status: [:open]).select(&:live?)
      end

      private

      def replace_leaderboard(contest)
        entries  = contest.entries.where(status: [:active, :complete])
                          .includes(:user, selections: { slate_matchup: [:team, :game] })
                          .order(score: :desc)
        matchups = contest.matchups.ranked.includes(:team, :opponent_team, :game)
        Turbo::StreamsChannel.broadcast_update_to(
          [contest, :live],
          target:  "contest_#{contest.id}_leaderboard",
          partial: "contests/turf_totals_leaderboard",
          # onchain_contest: nil — compact mode never renders on-chain blocks, and
          # a broadcast can't afford a synchronous RPC fetch.
          # show_completed_games: false — this stream feeds ONLY the live page,
          # whose Games row already lists completed games with scorers. Must mirror
          # live.html.erb's initial render or each goal re-injects the duplicate grid.
          locals:  { compact: true, show_completed_games: false, contest: contest, entries: entries, matchups: matchups, onchain_contest: nil }
        )
      rescue => e
        ErrorLog.capture!(e)
      end

      def replace_games(contest)
        Turbo::StreamsChannel.broadcast_update_to(
          [contest, :live],
          target:  "contest_#{contest.id}_games",
          partial: "contests/live_games",
          locals:  contest.games_by_phase.merge(contest: contest)
        )
      rescue => e
        ErrorLog.capture!(e)
      end

      # THE FOCUS PANEL IS ITS OWN TARGET, because it is not next to the strip in
      # the layout — the strip runs across the top, the focused game sits in the
      # left column above chat, and one stream target cannot span both. Same
      # locals as the strip: which of the sixteen tiles is visible is decided by
      # Alpine on the client, from state this payload never sees.
      def replace_focus(contest)
        Turbo::StreamsChannel.broadcast_update_to(
          [contest, :live],
          target:  "contest_#{contest.id}_focus",
          partial: "contests/live_focus",
          locals:  contest.games_by_phase.merge(contest: contest)
        )
      rescue => e
        ErrorLog.capture!(e)
      end

      def append_goal_feed(contest, goal, game)
        Turbo::StreamsChannel.broadcast_append_to(
          [contest, :live],
          target:  "contest_#{contest.id}_goal_feed",
          partial: "contests/goal_feed_item",
          # `goal` rides along now, not just its team: the live page animates the
          # scoring row per scoring TYPE (a touchdown takes the whole card, an
          # extra point is deliberately understated), and the type lives on the
          # Goal. Without it every score would fall back to the touchdown motion
          # and the vocabulary would say nothing.
          locals:  { event: "goal", goal: goal, team: goal.team, player: goal.player, game: game }
        )
      rescue => e
        ErrorLog.capture!(e)
      end

      def append_final_feed(contest, game)
        Turbo::StreamsChannel.broadcast_append_to(
          [contest, :live],
          target:  "contest_#{contest.id}_goal_feed",
          partial: "contests/goal_feed_item",
          locals:  { event: "final", goal: nil, team: nil, player: nil, game: game }
        )
      rescue => e
        ErrorLog.capture!(e)
      end
    end
  end
end
