require "test_helper"

# End-to-end: the scheduled job runs Deposits::OnchainReconciler through the
# real Solana::Vault.new seam (stubbed to FakeVault), proving the recurring
# sweep confirms on-chain and NEVER re-transfers.
class PendingDepositReconcilerJobTest < ActiveJob::TestCase
  setup { @user = users(:jordan) }

  def deposit_log(onchain_tx:, created_at:, status: "pending")
    TransactionLog.create!(
      user: @user, transaction_type: "deposit", amount_cents: 2500,
      direction: "credit", status: status, onchain_tx: onchain_tx,
      description: "Stripe deposit", created_at: created_at
    )
  end

  test "reconciles a landed stranded deposit to completed and never re-transfers" do
    log = deposit_log(onchain_tx: "SigLanded", created_at: 30.minutes.ago)
    vault = FakeVault.new(signature_statuses: { "SigLanded" => { "err" => nil, "confirmationStatus" => "confirmed" } })

    Solana::Vault.stub :new, vault do
      PendingDepositReconcilerJob.perform_now
    end

    assert_equal "completed", log.reload.status
    assert_empty vault.fund_calls, "the reconciler job must NEVER re-transfer"
  end

  test "flags an unconfirmable aged deposit as needs_review while leaving a fresh one pending" do
    stranded = deposit_log(onchain_tx: "SigMissing", created_at: 30.minutes.ago)
    fresh    = deposit_log(onchain_tx: "SigMissing", created_at: 1.minute.ago)
    vault = FakeVault.new(signature_statuses: {}) # not found on-chain

    Solana::Vault.stub :new, vault do
      PendingDepositReconcilerJob.perform_now
    end

    assert_equal "needs_review", stranded.reload.status
    assert_equal "pending",      fresh.reload.status
    assert_empty vault.fund_calls
    assert ErrorLog.where(target_type: "TransactionLog", target_id: stranded.id).exists?
  end

  test "older_than_minutes override widens the window" do
    log = deposit_log(onchain_tx: "SigLanded", created_at: 3.minutes.ago)
    vault = FakeVault.new(signature_statuses: { "SigLanded" => { "err" => nil, "confirmationStatus" => "finalized" } })

    # default 10-min threshold: 3-min-old row is in-flight, untouched
    Solana::Vault.stub :new, vault do
      PendingDepositReconcilerJob.perform_now
    end
    assert_equal "pending", log.reload.status

    # 1-min threshold: now eligible and confirmed -> completed
    Solana::Vault.stub :new, vault do
      PendingDepositReconcilerJob.perform_now(older_than_minutes: 1)
    end
    assert_equal "completed", log.reload.status
    assert_empty vault.fund_calls
  end
end
