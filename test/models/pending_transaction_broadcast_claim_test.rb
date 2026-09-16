require "test_helper"

# PendingTransaction's broadcast seam — the claim, the stamp, and the release.
#
# ── WHY A CLAIM EXISTS AT ALL ─────────────────────────────────────────────────
#
# A broadcast is a state READ, a simulation, a send, and then a verification
# costing one RPC call per claimed signer. `raise unless @tx.pending?` is a
# read, not a claim: two concurrent requests both pass it and both put a wire on
# the chain. Each rebuild mints fresh bytes, so the two wires carry different
# blockhashes and different signatures — two settlements land and only one is
# ever reconciled. These four methods are the exclusion, and they live on the
# model because TWO controllers broadcast these rows.
class PendingTransactionBroadcastClaimTest < ActiveSupport::TestCase
  def ptx
    PendingTransaction.create!(
      tx_type: "settle_contest", serialized_tx: "WIRE", status: "pending",
      initiator_address: "init", metadata: { settlements: [] }.to_json
    )
  end

  # THE REGRESSION for the concurrency half. Two objects over ONE row is how a
  # double-click reaches the controller; the database, not Ruby, decides.
  test "only one caller can claim a row for broadcast" do
    tx = ptx
    rival = PendingTransaction.find(tx.id)

    assert tx.claim_for_broadcast!, "the first caller wins the right to broadcast"
    assert_not rival.claim_for_broadcast!, "the second caller must lose it"
    assert_equal "submitted", rival.status, "and must see the state the row is ACTUALLY in"
  end

  test "a claim released after a provably un-sent failure is claimable again" do
    tx = ptx
    tx.claim_for_broadcast!
    tx.release_broadcast_claim!

    assert tx.pending?, "a transaction that never left the server stays retryable"
    assert tx.claim_for_broadcast!
  end

  # THE SECOND LINE. A release is only ever reached on
  # Solana::Vault::PreflightRejected, but a caller that reached for it on the
  # wrong error must still not be able to un-record a landed transaction.
  test "a release can never un-record a broadcast that happened" do
    tx = ptx
    tx.claim_for_broadcast!
    tx.record_broadcast!("SIG_THAT_LANDED")

    tx.release_broadcast_claim!

    assert_equal "SIG_THAT_LANDED", tx.tx_signature
    assert_equal "submitted", tx.status
    assert_not tx.pending?, "a landed transaction must never become re-broadcastable"
  end

  # The stamp is `update_columns` on purpose: no validation and no callback may
  # stand between a transaction that has left the server and the record of it.
  test "the stamp records the signature without running validations" do
    tx = ptx
    tx.claim_for_broadcast!
    tx.serialized_tx = nil # a row that could not be saved through update!

    assert tx.record_broadcast!("SIG_LANDED")
    assert_equal "SIG_LANDED", tx.reload.tx_signature
  end

  # The one state where a re-send is forbidden AND a signature may still be
  # recorded out of band — the reconciliation door #confirm opens.
  test "awaiting_reconciliation? names a claimed row whose answer was lost" do
    tx = ptx
    assert_not tx.awaiting_reconciliation?, "an unclaimed row is not stranded"

    tx.claim_for_broadcast!
    assert tx.awaiting_reconciliation?, "claimed, no signature — the wire may be on chain"

    tx.record_broadcast!("SIG")
    assert_not tx.awaiting_reconciliation?, "a recorded signature is an answer"
  end
end
