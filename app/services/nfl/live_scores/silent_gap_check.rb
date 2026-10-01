module Nfl
  module LiveScores
    # THE TRIPWIRE FOR A WEEK THAT VANISHES WITHOUT A SOUND.
    #
    # Measured on turf-monster-mainnet 2026-09-27. Regular season 2026 week 2:
    # ESPN reported all 16 games Final; we held all 16 at `status=scheduled` with
    # ZERO goals. An entire week of NFL scoring was never ingested, and the
    # Weeks 1-3 contest — 7 active PAID entries from 7 different people — scored
    # on two weeks out of three for ten days. The backfill moved the contest
    # total 1548.9 -> 2930.3 and CHANGED THE LEADERBOARD ORDER.
    #
    # WHY THIS OBJECT EXISTS AND NOT JUST A CRON. Nothing was broken in a way
    # anything could see. No exception, no anomaly, no `degraded_feed`, no
    # ErrorLog. The standings simply omitted a week and looked entirely
    # plausible — 1548.9 points is not obviously wrong. The gap would have been
    # found by a customer. And a scheduled poller fails the same silent way: a
    # cron that is never loaded, loses its `active_job: true` flag (which has
    # happened here, to all four entries at once), or dies on a bad deploy
    # produces exactly this state and reports nothing. So the schedule closes
    # the common case and THIS closes the case where the schedule itself failed.
    #
    # THE PREDICATE, once: a slot whose games are FINAL AT THE SOURCE but carry
    # ZERO scoring events here. It is asked against ESPN and not against a clock,
    # because a postponed game is legitimately unfinished and a 0-0 game is
    # legitimately unscored, and both look identical to a clock.
    #
    # WHAT IT COSTS. Nothing, on a healthy week. One indexed query against our
    # OWN rows finds the goal-less games whose kickoff is comfortably past, and a
    # week we have scored produces NONE — so `SlotResolver` is handed an empty
    # set, no slate is read, and no network request is made at all. Only once a
    # game already looks wrong is a second query spent resolving which slot to
    # ask ESPN about.
    #
    # WHAT IT DELIBERATELY DOES NOT DO: repair. The alert names the exact
    # command (`bin/nfl-live-poll --slot Y:T:W`) and stops there. Re-polling a
    # historical week unattended is the one act that can reach across the
    # grading/settlement seam, and a tripwire whose own remedy carries that risk
    # is worse than the silence it replaced. PollCycle refuses a settled slot on
    # its own, but the decision to reach back into a finished week stays a
    # human's.
    class SilentGapCheck
      # The alert. A named class rather than a bare StandardError so an operator
      # reading /admin/error_logs can tell this apart at a glance from the
      # exceptions the poller captures.
      class UnscoredSlotError < StandardError; end

      # HOW LONG AFTER KICKOFF A GOAL-LESS GAME BECOMES SUSPICIOUS. An NFL game
      # runs about three and a quarter hours; six covers overtime, a weather
      # delay, and a late start without ever calling a game that is still being
      # played "missing".
      SETTLE_GRACE = 6.hours

      # HOW FAR BACK IT LOOKS. Three weeks, so a gap survives the operator being
      # away for a fortnight — the incident ran ten days before anyone noticed —
      # while the candidate query stays bounded and cheap.
      #
      # IT IS A CLIFF, AND THE CLIFF IS DELIBERATE: an unrepaired gap pages four
      # times a day for three weeks and then goes quiet, because the slot leaves
      # the window. A gap nobody acted on in 21 days is not going to be fixed by a
      # 22nd day of the same page, and an unbounded lookback would re-page every
      # historical week forever on the first slate we never scored. The backstop
      # for a page that was ignored is the ErrorLog itself, which does not expire.
      LOOKBACK = 21.days

      # One slot's worth of missing scoring. `games` are human-readable lines,
      # not model objects: the only consumer is an alert message a person reads
      # at two in the morning.
      Gap = Data.define(:slot, :games) do
        def to_h = { slot: slot.to_h, games: games }
      end

      # `unreadable` is not padding. This object's whole claim is that silence
      # cannot be trusted, so a slot whose scoreboard did not arrive must be
      # distinguishable from a slot that agreed — otherwise an ESPN outage reads
      # as "no gaps found" and the tripwire has quietly stopped being one.
      Result = Data.define(:slots_checked, :gaps, :unreadable) do
        def clean? = gaps.empty?

        # A clean run only MEANS anything if every candidate slot was actually
        # read. Callers that report a verdict must say which of the two they got.
        def conclusive? = unreadable.empty?

        def to_h
          {
            slots_checked: slots_checked.map(&:to_h),
            gaps: gaps.map(&:to_h),
            unreadable: unreadable
          }
        end
      end

      SEASON_TYPES = { 1 => "Preseason", 2 => "Regular", 3 => "Postseason" }.freeze

      def self.call(...) = new(...).call

      def initialize(client: Espn::Client.new, now: Time.current)
        @client = client
        @now = now
        @gaps = []
        @unreadable = []
      end

      def call
        slots = candidate_slots
        slots.each { |slot| inspect_slot(slot) }

        Result.new(slots_checked: slots, gaps: @gaps, unreadable: @unreadable)
      end

      private

      attr_reader :client, :now

      # THE PREFILTER, and the reason a healthy week is free.
      #
      # Our own rows, no network: NFL games kicked off long enough ago to be
      # over, holding no Goal at all. `where.missing` is a LEFT JOIN with a NULL
      # test, so "holds no goals" is decided by the database rather than by
      # loading every game in three weeks. A week we have scored produces no
      # candidate games, so `SlotResolver` is handed an empty set, spends no
      # slate query, and names no slot to ask ESPN about.
      #
      # IT NO LONGER FILTERS ON THE SLOT COLUMNS, and that is the whole fix.
      # Requiring `season_year`/`season_type`/`week` to be non-null meant only a
      # slot the poller had ALREADY polled could ever become a candidate —
      # `PollCycle#upsert_game` is their only non-test writer — so the one state
      # this object exists to catch was the one state it could not see. Measured
      # on a freshly seeded database: 272 NFL games, ZERO carrying season_year.
      # The slot is resolved per game instead; see `SlotResolver`.
      #
      # `kickoff_at` STAYS the time bound, and it is the honest one: 256 of those
      # 272 carry it, and the 16 that do not are all of week 18, whose slate
      # carries no `starts_at` either. A game no source has placed in time cannot
      # be given a six-hour grace window by any means, and no contest is played
      # on that week. When the poller first reaches it, it stamps both.
      def candidate_slots
        games = Game.nfl
                    .where(kickoff_at: (now - LOOKBACK)..(now - SETTLE_GRACE))
                    .where.missing(:goals)
                    .to_a

        SlotResolver.call(games).sort_by { |slot| [slot.year, slot.season_type, slot.week] }
      end

      # ONE scoreboard request per suspicious slot, and the source's own verdict
      # is what decides. Our row's `status` is deliberately not consulted: in the
      # incident it read `scheduled`, which is precisely the lie being caught.
      def inspect_slot(slot)
        rows = Espn::Scoreboard.rows_from(
          client.scoreboard(year: slot.year, season_type: slot.season_type, week: slot.week)
        )

        missing = rows.filter_map { |row| unscored_final(row) }
        return if missing.empty?

        gap = Gap.new(slot: slot, games: missing)
        @gaps << gap
        alert!(gap)
      rescue Espn::Client::Error => e
        # A slot we could not read is neither clean nor a gap. Recorded so the
        # verdict can say so.
        @unreadable << "#{slot_label(slot)}: #{e.message}"
        Rails.logger.warn("[nfl_silent_gap_check] could not read #{slot_label(slot)}: #{e.message}")
      end

      # THE PREDICATE. Three conditions, and dropping any one of them turns this
      # into a pager that cries wolf:
      #
      #   1. the source says the game is COMPLETED — a postponed game is also
      #      ESPN state "post", and only `completed` separates them;
      #   2. the source reports POINTS — a genuine 0-0 final and zero goals here
      #      agree, and flagging it would page a human about nothing;
      #   3. we hold the game and it carries NO scoring events — the actual
      #      incident shape.
      #
      # A final the source reports that we hold NO row for at all is out of
      # scope: no SlateMatchup can point at a game that does not exist, so no
      # contest scores off it, and flagging it would fire on every week whose
      # slate we never built.
      def unscored_final(row)
        return nil unless row.status == "completed"
        return nil unless row.home_score.to_i.positive? || row.away_score.to_i.positive?

        game = GameLookup.find(row)
        return nil unless game
        return nil if game.goals.exists?

        "#{game.slug}: source says FINAL #{row.away_abbr} #{row.away_score}-#{row.home_score} " \
          "#{row.home_abbr}, we hold 0 scoring events"
      end

      # PAGE A HUMAN, with the remedy in the message.
      #
      # House convention (`Deposits::OnchainReconciler#flag!`,
      # `Contests::PendingReconciler#flag!`): a named error through
      # `ErrorLog.capture!`, which also fans out to Sentry where it is
      # configured. Everything goes in the MESSAGE rather than in `target`,
      # because the subject is a SLOT and not a record — and /admin/error_logs
      # only renders `target_name` alongside a `target_type`, so a bare handle
      # there would be invisible.
      #
      # It is not deduplicated, and that is deliberate. The check runs every six
      # hours, so an unrepaired gap pages four times a day until someone acts —
      # which is the correct volume for a week of paid contest scoring being
      # wrong, and is the opposite of the failure this whole task exists to fix.
      def alert!(gap)
        slot = gap.slot
        err = UnscoredSlotError.new(
          "NFL #{slot_label(slot)}: #{gap.games.length} game(s) are FINAL at ESPN but carry " \
          "zero scoring events here, so every contest on this slot is scoring short. " \
          "#{gap.games.join(' | ')}. " \
          "Repair with: bin/nfl-live-poll --slot #{slot.year}:#{slot.season_type}:#{slot.week} " \
          "(idempotent; skips a game whose every contest has SETTLED — add --allow-settled " \
          "to rewrite a graded contest's matchups on purpose)."
        )
        ErrorLog.capture!(err)
        Rails.logger.error("[nfl_silent_gap_check][gap] #{slot_label(slot)} games=#{gap.games.length}")
      end

      def slot_label(slot)
        "#{slot.year} #{SEASON_TYPES.fetch(slot.season_type, '?')} week #{slot.week}"
      end
    end
  end
end
