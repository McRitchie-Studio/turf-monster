# ONE POLLING CYCLE, ON A CLOCK INSTEAD OF ON A HUMAN.
#
# Until this job existed, `bin/nfl-live-poll` was the ONLY non-production-cron
# caller of Nfl::LiveScores::PollCycle, so production contests re-scored only
# when an agent happened to run the `live-score-watch` act. Nobody ran it between
# 2026-09-17 and 2026-09-23, and regular-season week 2 silently vanished: ESPN
# reported all 16 games Final while we held all 16 at `status=scheduled` with
# zero goals, and a contest with 7 active PAID entries scored on two weeks out of
# three for ten days.
#
# WHY IT POLLS UNCONDITIONALLY, EVERY FIVE MINUTES, ALL WEEK.
#
# The obvious economy is to only poll inside a game window — check whether any
# game kicks off soon or finished recently, and skip the request otherwise. That
# would cut ~288 scoreboard requests a day to ~40, and it is exactly the wrong
# trade here, because the window would be DERIVED FROM THE DATA THIS JOB
# MAINTAINS. A slate that was never built, kickoff times that were never
# refreshed, or a week whose rows carry a null slot all produce an empty window —
# so the gate closes itself, permanently and silently, in precisely the situation
# the poll is needed. That is the defect this job exists to fix, wearing a
# cleverer costume.
#
# So the cadence is a floor with no conditions on it. One scoreboard request per
# tick covers every game in the slot ESPN considers current; a per-game summary
# request is spent only when a score actually moved, which across a full Sunday
# averages under one. Between weeks the cycle upserts kickoff times and statuses
# and writes no goals, which is cheap and keeps the board honest.
#
# It is NOT a replacement for the `live-score-watch` act. Five minutes is a floor
# on latency, not a target: an operator watching a live contest still polls on a
# tighter loop. What this guarantees is that a week can never again disappear
# because nobody was watching.
#
# WHAT IT DOES NOT DECIDE. Everything — which play is worth what, whether a game
# is final, whether a contest re-scores, and whether a settled contest is in
# range — lives in PollCycle, under test. This job picks no slot (nil means "ask
# ESPN what is current", which is a far more reliable answer than anything we
# could compute from a calendar) and passes no override, so the settled-contest
# refusal always applies to it.
module Nfl
  class LivePollJob < ApplicationJob
    queue_as :default

    # Anomalies are REPORTED, never fatal — the feed is not ours and will have
    # bad minutes, and a bad minute must not turn into a Sidekiq retry storm
    # against a third party. They go to the log, where the watch already looks.
    def perform
      result = LiveScores::PollCycle.call
    rescue Espn::Client::Error => e
      # The one genuinely fatal case: the scoreboard itself did not arrive, so
      # this cycle observed nothing. Let Sidekiq retry it rather than swallowing
      # it — but do not raise past the retry budget for an outage we do not own.
      Rails.logger.warn("[nfl_live_poll] scoreboard unavailable: #{e.message}")
      nil
    else
      log(result)
      start_watch
      result
    end

    private

    # Hand over to the tight loop when there is a game to watch (see
    # LiveWatchJob). After the cycle, so its gate reads statuses this tick just
    # wrote; and rescued, because this job's own duty — the floor — is already
    # done and must not be failed by a convenience stacked on top of it.
    def start_watch
      LiveWatchJob.ensure_running
    rescue StandardError => e
      ErrorLog.capture!(e)
    end

    def log(result)
      return if result.quiet?

      Rails.logger.info(
        "[nfl_live_poll] #{result.changes.length} change(s), #{result.anomalies.length} anomaly(ies), " \
        "#{result.games_seen} games, slot=#{result.slot&.to_h.inspect}"
      )
      result.anomalies.each do |anomaly|
        Rails.logger.warn("[nfl_live_poll][#{anomaly.kind}] #{anomaly.detail}")
      end
    end
  end
end
