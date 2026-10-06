# Queues the drop announcement for every address DropAnnouncement says is still
# owed it. DropAnnouncement#send! runs it in the admin's request (perform_now);
# it is a job so it can also be re-driven from a console with perform_later. The guards (admin, drop time, typed count) ran in the controller; the
# guard that matters here is the per-row claim in
# DropSignup#deliver_announcement!, so this job is safe to retry, to run twice
# at once, or to run again after a partial failure: a row already claimed is
# skipped, and each address is mailed at most once.
#
# One row failing to queue never stops the rest: it is logged, its claim is
# released (it stays announceable), and the job moves on.
class DropAnnouncementJob < ApplicationJob
  queue_as :mailers

  def perform(slate_key)
    queued = 0
    failed = 0
    DropSignup.announceable(slate_key).find_each do |signup|
      queued += 1 if signup.deliver_announcement!
    rescue StandardError => e
      failed += 1
      Rails.logger.error("[drop-announcement] queue_failed signup=#{signup.id} #{e.class}: #{e.message}")
      begin
        ErrorLog.capture!(e)
      rescue StandardError
        nil
      end
    end
    Rails.logger.info("[drop-announcement] slate=#{slate_key} queued=#{queued} failed=#{failed}")
    { queued: queued, failed: failed }
  end
end
