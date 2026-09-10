require "test_helper"

# Reconciler for stranded `pending` deposit TransactionLog rows (the gap left by
# the StripeDepositJob claim-first double-transfer fix). The reconciliation is an
# ON-CHAIN CHECK, never a blind status flip, and it is READ-ONLY — it must never
# re-transfer. FakeVault#client.confirm_transaction mirrors the real
# getSignatureStatuses envelope: { "value" => [ status_or_nil ] }.
class Deposits::OnchainReconcilerTest < ActiveSupport::TestCase
  setup { @user = users(:jordan) }

  # Build a deposit TransactionLog. created_at is honored by ActiveRecord on
  # create when explicitly supplied, so we can age a row past the threshold.
  def deposit_log(status: "pending", onchain_tx: nil, created_at: 30.minutes.ago, amount_cents: 2500)
    TransactionLog.create!(
      user: @user, transaction_type: "deposit", amount_cents: amount_cents,
      direction: "credit", status: status, onchain_tx: onchain_tx,
      description: "Stripe deposit", created_at: created_at
    )
  end

  def landed_vault(sig)
    FakeVault.new(signature_statuses: { sig => { "err" => nil, "confirmationStatus" => "finalized" } })
  end

  test "aged pending deposit whose transfer LANDED is reconciled to completed — and never re-transfers" do
    log = deposit_log(onchain_tx: "SigLanded")
    vault = landed_vault("SigLanded")

    stats = Deposits::OnchainReconciler.run(older_than: 10.minutes, vault: vault)

    assert_equal "completed", log.reload.status
    assert_equal 1, stats[:reconciled]
    assert_empty vault.fund_calls, "the reconciler must NEVER call the transfer path"
  end

  test "aged pending deposit whose signature is NOT FOUND on-chain is flagged needs_review, not completed, not re-transferred" do
    log = deposit_log(onchain_tx: "SigMissing")
    vault = FakeVault.new(signature_statuses: {}) # confirm_transaction => value:[nil]

    assert_no_difference -> { TransactionLog.completed.count } do
      Deposits::OnchainReconciler.run(older_than: 10.minutes, vault: vault)
    end

    assert_equal "needs_review", log.reload.status
    assert_empty vault.fund_calls
    assert ErrorLog.where(target_type: "TransactionLog", target_id: log.id).exists?,
           "a stranded deposit must alert a human (ErrorLog)"
  end

  test "aged pending deposit that FAILED on-chain (meta.err present) is flagged, not completed" do
    log = deposit_log(onchain_tx: "SigErr")
    vault = FakeVault.new(signature_statuses: {
                            "SigErr" => { "err" => { "InstructionError" => [0, { "Custom" => 1 }] },
                                          "confirmationStatus" => "finalized" }
                          })

    Deposits::OnchainReconciler.run(older_than: 10.minutes, vault: vault)

    assert_equal "needs_review", log.reload.status
    assert_empty vault.fund_calls
  end

  test "aged pending deposit with NO recorded signature cannot be confirmed => needs_review + alert, never completed" do
    log = deposit_log(onchain_tx: nil)
    vault = FakeVault.new

    Deposits::OnchainReconciler.run(older_than: 10.minutes, vault: vault)

    assert_equal "needs_review", log.reload.status
    assert_empty vault.fund_calls
    assert ErrorLog.where(target_type: "TransactionLog", target_id: log.id).exists?
  end

  test "a still-confirming (processed) signature is left pending for the next sweep — neither completed nor flagged" do
    log = deposit_log(onchain_tx: "SigProcessing")
    vault = FakeVault.new(signature_statuses: {
                            "SigProcessing" => { "err" => nil, "confirmationStatus" => "processed" }
                          })

    stats = Deposits::OnchainReconciler.run(older_than: 10.minutes, vault: vault)

    assert_equal "pending", log.reload.status
    assert_equal 1, stats[:skipped]
    assert_empty vault.fund_calls
  end

  test "FRESH pending deposit (under threshold) is left untouched" do
    log = deposit_log(onchain_tx: "SigLanded", created_at: 2.minutes.ago)
    vault = landed_vault("SigLanded")

    stats = Deposits::OnchainReconciler.run(older_than: 10.minutes, vault: vault)

    assert_equal "pending", log.reload.status
    assert_equal 0, stats[:reconciled]
    assert_empty vault.fund_calls
  end

  test "MUTATION GUARD: completion is gated on the on-chain check — a not-found signature is NEVER completed" do
    # A blind-complete implementation (flip pending -> completed WITHOUT
    # confirming the signature landed) would fail this: the signature is not on
    # chain, yet the row must NOT be completed.
    log = deposit_log(onchain_tx: "SigMissing")
    vault = FakeVault.new(signature_statuses: {})

    Deposits::OnchainReconciler.run(older_than: 10.minutes, vault: vault)

    refute_equal "completed", log.reload.status
  end

  test "non-deposit pending rows (e.g. withdrawals) are ignored" do
    wd = TransactionLog.create!(user: @user, transaction_type: "withdrawal", amount_cents: 2500,
                                direction: "debit", status: "pending", created_at: 1.hour.ago)
    vault = FakeVault.new

    Deposits::OnchainReconciler.run(older_than: 10.minutes, vault: vault)

    assert_equal "pending", wd.reload.status
    assert_empty vault.fund_calls
  end
end
