module Nfl
  module LiveScores
    # WHICH ESPN SLOT A GAME WE HOLD BELONGS TO — resolved from the columns
    # production actually fills, not the ones the poller leaves behind.
    #
    # THE BUG THIS EXISTS TO CLOSE. `SilentGapCheck` used to find its candidate
    # slots by requiring `games.season_year`, `season_type` and `week` to be
    # non-null. `PollCycle#upsert_game` is the ONLY non-test writer of those
    # three columns, so that prefilter could see a slot ONLY AFTER the poller had
    # already succeeded against it — and a slot the poller never reached is
    # exactly the failure the tripwire exists to catch. Pointed at a faithful
    # rebuild of the 2026 week-2 rows it reported a CONCLUSIVE CLEAN WEEK.
    #
    # MEASURED on a freshly seeded database, not inferred:
    #
    #   272 NFL games, 0 carrying season_year / season_type / week
    #   256 carrying kickoff_at  (the 16 without are all of week 18)
    #    18 slates, 18 resolving a year and exactly one week
    #   544 slate_matchups
    #
    # So the SLATE is the record that reliably knows. That is not a coincidence:
    # a slate IS a slot — "NFL 2026 Week 2" — and `Slate#season_year` and
    # `Slate#week_range` are the readers every other surface already goes
    # through, each carrying a name fallback for the rows written before the
    # columns existed. `db/seeds/nfl_2026.rb` writes no `week` column at all
    # (0 of 17 before the odds CSV runs), and the name fallback is what makes
    # those seeded slates resolvable anyway.
    #
    # THE SLOT IS ONLY A REQUEST KEY, which is what makes a generous answer the
    # safe one. `SilentGapCheck#unscored_final` re-derives the game from each
    # scoreboard row it gets back, so an extra slot costs one request and can
    # never produce a false alert — while a missing slot is total blindness. Hence
    # a span slate that cannot say which of its weeks a game sits in contributes
    # ALL of them rather than none.
    module SlotResolver
      # Every slot the given games could belong to, de-duplicated.
      #
      # The games are partitioned first so a fully stamped set spends no slate
      # query at all: on a healthy week there are no candidates, and after a
      # successful poll every row carries its own slot.
      def self.call(games)
        games = Array(games)
        return [] if games.empty?

        stamped, unstamped = games.partition { |game| own_slot(game) }
        slots = stamped.map { |game| own_slot(game) }
        slots.concat(slate_slots(unstamped)) if unstamped.any?
        slots.uniq
      end

      # THE GAME'S OWN COLUMNS WIN when it has them, because ESPN wrote them for
      # that game. It is both the authoritative answer and the free one — no join.
      # All three, not any: a half-stamped row names no slot ESPN can serve.
      def self.own_slot(game)
        return nil if game.season_year.nil? || game.season_type.nil? || game.week.nil?

        PollCycle::Slot.new(year: game.season_year, season_type: game.season_type, week: game.week)
      end

      # ONE query for every unstamped game, then the slates answer. `includes`
      # rather than a per-matchup load: a whole broken week is 16 games and 32
      # matchups, and this runs on a cron.
      def self.slate_slots(games)
        SlateMatchup.where(game_slug: games.map(&:slug))
                    .includes(:slate)
                    .flat_map { |matchup| slots_from(matchup) }
      end

      def self.slots_from(matchup)
        slate = matchup.slate
        return [] if slate.nil?

        # `Slate#season_year` reads the `year` COLUMN and falls back to the
        # 4-digit year in the name. It returns a String because every other
        # caller compares it to another #season_year; a slot is asked of ESPN as
        # a number, so it is converted exactly once, here.
        year = slate.season_year
        return [] if year.blank?

        weeks_for(matchup, slate).map do |week|
          PollCycle::Slot.new(year: year.to_i, season_type: slate.season_type, week: week)
        end
      end

      # WEEK, IN PRECEDENCE ORDER — three sources because three writers fill
      # three different ones, and no single one is populated everywhere:
      #
      #   1. the MATCHUP's week — `Nfl::BuildSpanSlate#rebuild_matchups!` and
      #      `Nfl::CacheExpectedTeamTotals` both write it, and it is the only
      #      source that can say which week of a SPAN a game sits in;
      #   2. the SLATE's week column — written by the odds-CSV slate build;
      #   3. the week in the slate's NAME, through `Slate#week_range` — the only
      #      one `db/seeds/nfl_2026.rb` leaves behind, and therefore the one that
      #      resolves the 2026 week-2 rows.
      #
      # A span slate reached through (3) names several weeks and cannot say which
      # is the game's, so it contributes every one. A slate naming no week at all
      # — every World Cup slate — contributes nothing, because there is no slot
      # to ask ESPN for.
      def self.weeks_for(matchup, slate)
        return [matchup.week] if matchup.week.present?
        return [slate.week] if slate.week.present?

        slate.week_range&.to_a || []
      end
    end
  end
end
