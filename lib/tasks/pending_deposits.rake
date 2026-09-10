# Ad-hoc reconciliation of stranded `pending` TransactionLog DEPOSIT rows.
#
# StripeDepositJob claims a deposit row before the irreversible on-chain
# transfer; a die-after-claim leaves it `pending`. Deposits::OnchainReconciler
# CONFIRMS the recorded signature on-chain (READ-ONLY) and either finalizes a
# landed row to `completed` or flags an unconfirmable one `needs_review` +
# alerts. It NEVER re-transfers. This task is the manual counterpart to the
# scheduled PendingDepositReconcilerJob (config/schedule.yml).
#
#   bin/rails pending_deposits:reconcile        # default 10-minute threshold
#   bin/rails pending_deposits:reconcile[2]     # 2-minute threshold
namespace :pending_deposits do
  desc "Reconcile stranded pending deposit rows older than N minutes (default 10) against the chain"
  task :reconcile, [:minutes] => :environment do |_t, args|
    older_than = args[:minutes] ? args[:minutes].to_f.minutes : Deposits::OnchainReconciler::RECONCILE_AFTER
    stats = Deposits::OnchainReconciler.run(older_than: older_than)
    puts "✓ deposit reconcile: reconciled=#{stats[:reconciled]} flagged=#{stats[:flagged]} " \
         "skipped=#{stats[:skipped]} errors=#{stats[:error]}"
  end
end
