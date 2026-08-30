module Live
  # WHICH GAME THE BOARD OPENS ON.
  #
  # Hand it the games of one SLOT — an NFL week, a soccer matchday, a day's
  # card — and it answers with the one the page should lead with. It reads
  # exactly three things off each game: `status`, `kickoff_at`, and the
  # operator's `focus_rank`. Nothing about the NFL is baked in, which is why
  # the same ladder serves a league that kicks nine games off at once and one
  # that plays two a week; the differences live in POLICIES below.
  #
  # THE LADDER. Four rungs, tried in order, first answer wins:
  #
  #   1. LIVE      a game is being played  -> the best-ranked one
  #   2. IMMINENT  none is, but the next kickoff is inside the lead-in window
  #                -> the best-ranked game in that kickoff's WAVE
  #   3. HOLDOVER  neither -> the game that finished most recently
  #   4. FALLBACK  nothing has finished either -> the soonest upcoming game
  #
  # WHY RANK ONLY BREAKS TIES. Rank never selects across rungs, only within
  # one. A first-in-the-order Sunday-night game must not own the board all
  # afternoon while nine other games are actually being played, and it does
  # not: rung 1 sees only games in progress, so at 2pm the highest AMONG THE
  # LIVE ONES wins. That is the operator's rule — "highest ranked, has not
  # finished, and must have been started" — expressed as the shape of the
  # candidate set rather than as a condition bolted onto a sort.
  #
  # AN UNRANKED WEEK IS NOT A DEGRADED ONE. `focus_rank` is a position in one
  # list covering the whole week, seeded in kickoff order by the board that
  # sets it — and with every rank nil this sorts by kickoff anyway. So a week
  # nobody has dragged behaves exactly like one dragged into the order it
  # already had.
  #
  # WHY THE WAVE. Sunday at 9am nothing is live, and every remaining game is
  # "upcoming" — including the night game, which is usually the highest-ranked
  # of the week. Ranking the whole upcoming list would put an 8:20pm kickoff on
  # the board at breakfast and leave it there through the entire one o'clock
  # window. The wave narrows the candidates to the games going off TOGETHER
  # (within `wave` of the earliest upcoming kickoff), so the morning's board
  # leads with the best-ranked one o'clock game and the night game waits its
  # turn.
  #
  # WHY THE HOLDOVER. When the last game of a day ends, the honest answer to
  # "what is on" is nothing, and the board must not lurch to a game that kicks
  # off tomorrow while people are still talking about the one that just
  # finished. Rung 3 keeps the finished game up, and rung 2 is what eventually
  # takes it down — the next game becomes IMMINENT `lead_in` before its
  # kickoff, which for the NFL's 12 hours means Sunday night football holds the
  # board overnight and Monday night football takes it on Monday morning.
  # Two constants, no calendar arithmetic, no timezone to be wrong about.
  module FocusGame
    # PER-LEAGUE TUNING, and the only place a sport is named.
    #
    #   lead_in  how long before kickoff an upcoming game may take the board
    #   wave     how far apart two kickoffs can be and still count as one wave
    #
    # The NFL's numbers come from its own shape: 12 hours turns "the night game
    # holds until morning" into a window, and 90 minutes covers a one o'clock
    # slate whose kickoffs are staggered to 1:00 and 1:05 without reaching the
    # 4:25 games. Soccer's are tighter because its cards are.
    POLICIES = {
      nfl:    { lead_in: 12.hours, wave: 90.minutes },
      soccer: { lead_in: 6.hours,  wave: 30.minutes }
    }.freeze

    # Sentinels, so nil never has to be special-cased at each comparison. An
    # unranked game sorts after every ranked one — INFINITY rather than some
    # large number, because the order covers a whole week and nothing should
    # depend on a guess about how many games that is; a game with no kickoff
    # sorts last among the upcoming (it is not soon) and FIRST among the
    # finished (a game we cannot date is not the one that just ended).
    UNRANKED   = Float::INFINITY
    FAR_FUTURE = Time.utc(9999, 1, 1).freeze
    LONG_PAST  = Time.utc(1970, 1, 1).freeze

    class << self
      # The focus game's slug, or nil for an empty set. What the views want.
      def call(games, policy: :nfl, now: Time.current)
        pick(games, policy: policy, now: now)&.slug
      end

      # The focus Game itself. What the tests and any future caller want.
      def pick(games, policy: :nfl, now: Time.current)
        games = Array(games)
        return nil if games.empty?

        rules    = policy_for(policy)
        phases   = games.group_by { |game| phase(game, now) }
        upcoming = (phases[:upcoming] || []).sort_by { |game| [kickoff(game), game.slug.to_s] }

        best_ranked(phases[:started] || []) ||                            # 1. LIVE
          imminent(upcoming, rules, now) ||                               # 2. IMMINENT
          last_finished(phases[:finished] || []) ||                       # 3. HOLDOVER
          upcoming.first                                                  # 4. FALLBACK
      end

      private

      # STARTED, not merely in_progress. The poller flips `status` on its own
      # cycle, so between a kickoff and the next poll a game that is being
      # played still reads as "scheduled" — and a board that answers "nothing
      # is on" while the ball is in the air is wrong in the one minute it most
      # matters. A passed kickoff counts, which is the same test
      # Contest#games_by_phase already applies.
      def phase(game, now)
        return :finished if game.completed?
        return :started  if game.live? || (game.kickoff_at.present? && game.kickoff_at <= now)

        :upcoming
      end

      def best_ranked(games)
        games.min_by { |game| [game.focus_rank || UNRANKED, kickoff(game), game.slug.to_s] }
      end

      def imminent(upcoming, rules, now)
        next_up = upcoming.first
        return nil unless next_up&.kickoff_at
        return nil if next_up.kickoff_at > now + rules[:lead_in]

        wave = upcoming.select do |game|
          game.kickoff_at.present? && game.kickoff_at <= next_up.kickoff_at + rules[:wave]
        end
        best_ranked(wave)
      end

      def last_finished(finished)
        finished.max_by { |game| [kickoff(game, missing: LONG_PAST), game.slug.to_s] }
      end

      def kickoff(game, missing: FAR_FUTURE)
        game.kickoff_at || missing
      end

      # A hash passes straight through so a caller can tune a one-off board
      # without inventing a league. An unknown NAME raises rather than falling
      # back to the NFL's numbers: a policy that silently is not the one you
      # asked for is a board that is subtly wrong for a season.
      def policy_for(policy)
        return policy if policy.is_a?(Hash)

        POLICIES.fetch(policy.to_sym) do
          raise ArgumentError,
                "unknown focus policy #{policy.inspect} — known: #{POLICIES.keys.join(', ')}"
        end
      end
    end
  end
end
