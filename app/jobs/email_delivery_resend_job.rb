# Re-drives EmailDelivery rows that were never sent and have nothing left to
# send them.
#
# WHY THIS EXISTS. EmailDelivery.deliver records the intent durably and then
# enqueues EmailDeliveryJob; deliver_now! marks the row sent, or records the
# error and re-raises so Sidekiq retries. That covers a send that FAILS. It does
# not cover a send that reports nothing — and on 2026-09-07 that is exactly what
# happened on mainnet: settling turf-totals-alpha-contest-v1 paid a real
# winner $100 and left their winner email at sent=false,
# sent_at=nil, error=nil, while a row created in the SAME SECOND for the other
# winner sent fine. (The player is deliberately not named — this repo is
# PUBLIC. The row id is on the task record.) Sidekiq held nothing — enqueued 0, retry 0, dead 0. A real
# player had been paid and would never have been told.
#
# EVERY BOUND BELOW IS LOAD-BEARING. This job re-sends real mail to real people
# and cannot be un-sent, so it is scoped in three dimensions at once. Each was a
# blocking review finding, each measured rather than argued (PR #611):
#
#   1. CAPTURE ENVIRONMENTS ARE EXCLUDED ENTIRELY. Under LOCAL_EMAIL_CAPTURE=1
#      — every agent worktree stack — EmailDelivery.deliver writes the row and
#      NEVER enqueues (email_delivery.rb:26), and deliver_now! returns early
#      setting only `error`, so the row can never reach sent. That is bit-for-bit
#      the stranded signature this job hunts, which made it a non-terminating
#      loop: a reviewer measured three consecutive ticks re-queueing the same row
#      (requeued=1, requeued=1, requeued=1), 72 times a day, forever, growing
#      with every captured email the app has ever recorded. sidekiq_cron.rb has
#      no env guard, so the schedule loads wherever Sidekiq boots. The guard has
#      to live here.
#
#   2. THERE IS A CEILING, NOT JUST A FLOOR. A floor-only scope sweeps the entire
#      table on its first tick — email_deliveries dates to 2026-06-10 and is
#      never pruned. Production held 0 unsent rows when this shipped (36 rows
#      total, measured), so the blast radius was nil that day; the ceiling is
#      what keeps it nil after a future outage leaves a month of stragglers.
#      Older rows are NOT silently dropped — they are counted into the log line
#      so a real backlog is visible and can be released deliberately.
#
#   3. ONE TICK IS CAPPED. A backlog drains across ticks instead of enqueueing
#      thousands of sends in one pass. Oldest first, so the drain is
#      deterministic and the oldest stragglers recover first.
#
# Rows that failed LOUDLY are swept too. They sit in Sidekiq's retry ladder,
# which does eventually exhaust; leaving them out would mean a provider outage
# never recovers once it does. So this is not the narrow "no error" sweep the
# original description claimed — it is every unsent row inside the window.
#
# Re-enqueues rather than delivering inline: EmailDeliveryJob owns the send, so
# there is one path to the provider rather than a second that could drift.
# (EmailDelivery.resend_unsent! re-enqueues every unsent row with no bounds at
# all. This job deliberately does not call it — the bounds above are the point.)
class EmailDeliveryResendJob < ApplicationJob
  queue_as :default

  # Younger than this and the row is still in flight, not stranded: the row and
  # its job are created in the same breath, so sweeping here double-sends.
  STRANDED_AFTER = 30.minutes

  # Older than this and a human should decide. Re-sending months-old
  # "you won $100" mail is a worse incident than the one this fixes.
  SWEEP_WINDOW = 7.days

  # Per-tick ceiling; a backlog drains over successive ticks.
  BATCH_LIMIT = 100

  # Never let an operator override collapse the in-flight guard: 0 is truthy in
  # Ruby, so a bare `|| STRANDED_AFTER` would accept 0 and sweep rows created in
  # the same instant.
  MIN_STRANDED_MINUTES = 1

  def perform(stranded_after_minutes: nil)
    if Studio.local_email_capture?
      Rails.logger.info("[email_delivery_resend] skipped: local email capture is on, nothing here can send")
      return 0
    end

    minutes = [stranded_after_minutes&.to_f || STRANDED_AFTER.in_minutes, MIN_STRANDED_MINUTES].max
    cutoff  = minutes.minutes.ago
    floor   = SWEEP_WINDOW.ago

    in_window = EmailDelivery.unsent.where(created_at: floor..cutoff).order(:created_at)
    ids       = in_window.limit(BATCH_LIMIT).pluck(:id)
    too_old   = EmailDelivery.unsent.where(created_at: ...floor).count

    ids.each { |id| EmailDeliveryJob.perform_later(id) }

    Rails.logger.info(
      "[email_delivery_resend] requeued=#{ids.size} too_old_to_sweep=#{too_old} " \
      "cutoff=#{cutoff.iso8601} floor=#{floor.iso8601}" \
      "#{" ids=#{ids.first(20).join(',')}#{'…' if ids.size > 20}" unless ids.empty?}"
    )
    ids.size
  end
end
