# Recurring reconciler for stranded `pending` Contest rows.
#
# ContestsController#finalize saves the Contest row BEFORE it broadcasts
# `create_contest` (PR #551), so a crash between the two leaves a `pending` row
# holding a uniquely-indexed slug with no money behind it. This job runs
# Contests::PendingReconciler, which READS the derived Contest PDA and either
# promotes a row whose PDA exists (create_contest is atomic — the account
# existing is the funding proof) or deletes a row whose PDA does not. It never
# signs, broadcasts, or transfers.
#
# Scheduled every 15 minutes via config/schedule.yml (sidekiq-cron); the 10-min
# reconcile threshold means an in-flight finalize is never touched.
class PendingContestReconcilerJob < ApplicationJob
  queue_as :default

  def perform(older_than_minutes: nil)
    older_than = older_than_minutes ? older_than_minutes.to_f.minutes : Contests::PendingReconciler::RECONCILE_AFTER
    Contests::PendingReconciler.run(older_than: older_than)
  end
end
