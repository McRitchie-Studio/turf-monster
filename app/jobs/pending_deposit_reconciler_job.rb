# Recurring reconciler for stranded `pending` TransactionLog DEPOSIT rows.
#
# StripeDepositJob claims a `pending` deposit row before the irreversible
# on-chain transfer (OPSEC-022). A die-after-claim (or a completion-write fault)
# leaves that row stranded — SAFE (never re-transfers), but AMBIGUOUS about
# whether the transfer landed. This job runs Deposits::OnchainReconciler, which
# CONFIRMS the recorded signature on-chain (READ-ONLY) and either finalizes a
# landed row to `completed` or flags an unconfirmable one `needs_review` and
# alerts a human. It NEVER re-transfers.
#
# Scheduled every 15 minutes via config/schedule.yml (sidekiq-cron); the 10-min
# reconcile threshold means an in-flight deposit is never touched.
class PendingDepositReconcilerJob < ApplicationJob
  queue_as :default

  def perform(older_than_minutes: nil)
    older_than = older_than_minutes ? older_than_minutes.to_f.minutes : Deposits::OnchainReconciler::RECONCILE_AFTER
    Deposits::OnchainReconciler.run(older_than: older_than)
  end
end
