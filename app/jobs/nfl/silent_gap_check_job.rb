# THE HALF THAT HOLDS WHEN THE SCHEDULE ITSELF FAILS.
#
# Nfl::LivePollJob closes the common case. This closes the case where that job
# never ran — and a cron failing is not hypothetical here: on 2026-08-25 a merge
# resolution dropped `active_job: true` from all four entries in
# config/schedule.yml at once and NO scheduled job ran in either environment for
# a day, with every dashboard reading healthy (see
# test/initializers/sidekiq_cron_schedule_test.rb).
#
# A poller that stops produces exactly the 2026 week-2 state: games Final at ESPN
# carrying zero scoring events here, standings quietly short a week, no error and
# no anomaly anywhere. So the tripwire is checked on its own clock, and it does
# not trust the poller's own health to do it.
#
# WHY EVERY SIX HOURS. The check costs nothing on a healthy week — its candidate
# set is one indexed query over our own goal-less games, and a week we have scored
# produces no candidates and therefore no network request. Six hours bounds the
# worst-case detection latency at a quarter of a day (the incident ran ten days)
# while keeping an unrepaired gap to four pages a day: loud enough to be acted
# on, quiet enough not to bury the other alerts. There is deliberately NO
# deduplication — a week of paid contest scoring being wrong should nag.
module Nfl
  class SilentGapCheckJob < ApplicationJob
    queue_as :default

    def perform
      result = LiveScores::SilentGapCheck.call

      # A CLEAN RUN THAT COULD NOT READ THE SOURCE IS NOT A CLEAN RUN, and the
      # log line has to say which one happened, or an ESPN outage reads as "no
      # gaps found" and the tripwire has quietly stopped being one.
      verdict = if !result.clean?
        "#{result.gaps.length} GAP(S) — see ErrorLog"
      elsif result.conclusive?
        "clean"
      else
        "INCONCLUSIVE — #{result.unreadable.length} slot(s) unreadable: #{result.unreadable.join('; ')}"
      end

      Rails.logger.info(
        "[nfl_silent_gap_check] #{result.slots_checked.length} suspicious slot(s) checked: #{verdict}"
      )
      result
    end
  end
end
