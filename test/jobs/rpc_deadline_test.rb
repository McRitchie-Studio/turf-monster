require "test_helper"

# A job's Solana calls run under Solana::Deadline.job_seconds, set by
# ApplicationJob, unless the job names a LONG_BUDGET entry.
class RpcDeadlineJobTest < ActiveJob::TestCase
  class ProbeJob < ApplicationJob
    cattr_accessor :seen

    def perform
      self.class.seen = [Current.rpc_long_budget, Solana::Deadline.remaining]
    end
  end

  class SweepProbeJob < ProbeJob
    self.rpc_long_budget = :reconcile_sweep
  end

  test "a job runs under a deadline larger than a request's" do
    ProbeJob.perform_now
    name, left = ProbeJob.seen

    assert_nil name
    assert_in_delta 120, left, 1
    assert_operator left, :>, Solana::Deadline::WEB
    assert_nil Current.rpc_deadline, "the deadline ends with the job"
  end

  test "SOLANA_JOB_DEADLINE sets the job deadline" do
    ENV["SOLANA_JOB_DEADLINE"] = "300"
    ProbeJob.perform_now

    assert_in_delta 300, ProbeJob.seen.last, 1
  ensure
    ENV.delete("SOLANA_JOB_DEADLINE")
  end

  test "a job run inside a request keeps the request's sooner deadline" do
    Solana::Deadline.within(Solana::Deadline::WEB) { ProbeJob.perform_now }

    assert_operator ProbeJob.seen.last, :<=, Solana::Deadline::WEB
  end

  test "a job that names a long budget runs outside the deadline" do
    SweepProbeJob.perform_now

    assert_equal [:reconcile_sweep, nil], ProbeJob.seen
  end

  test "the reconciler and refresh jobs name their long budget" do
    assert_equal :reconcile_sweep, PendingContestReconcilerJob.rpc_long_budget
    assert_equal :reconcile_sweep, PendingDepositReconcilerJob.rpc_long_budget
    assert_equal :reconcile_sweep, Entries::OnchainReconcileJob.rpc_long_budget
    assert_equal :free_entries_refresh, Admin::FreeEntriesRefreshJob.rpc_long_budget
    assert_nil TokenPurchaseJob.rpc_long_budget, "CONTROL: an ordinary job"
  end
end
