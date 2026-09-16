require "test_helper"

# PendingTransaction's broadcast seam — the claim-and-stamp, the rewind, and the
# four-way reconciliation.
#
# ── WHY A CLAIM EXISTS AT ALL ─────────────────────────────────────────────────
#
# A broadcast is a state READ, a simulation, a send, and then a verification
# costing one RPC call per claimed signer. `raise unless @tx.pending?` is a
# read, not a claim: two concurrent requests both pass it and both put a wire on
# the chain. Each rebuild mints fresh bytes, so the two wires carry different
# blockhashes and different signatures — two settlements land and only one is
# ever reconciled.
#
# ── AND WHY THE SIGNATURE IS PART OF THE CLAIM ───────────────────────────────
#
# A transaction's signature is the first 64 bytes of its own signed wire, so the
# server holds it before it sends. Writing it in the SAME statement that takes
# the claim is what keeps a failed broadcast recoverable: the row always names
# its transaction, so the chain can be asked what became of it. The earlier
# design stamped from the RPC's reply, so any failure that ate the reply left a
# claimed row with no signature and no door out of it.
class PendingTransactionBroadcastClaimTest < ActiveSupport::TestCase
  def ptx
    PendingTransaction.create!(
      tx_type: "settle_contest", serialized_tx: "WIRE", status: "pending",
      initiator_address: "init", metadata: { settlements: [] }.to_json
    )
  end

  def landed_status    = { "err" => nil, "confirmationStatus" => "confirmed" }
  def failed_status    = { "err" => { "InstructionError" => [0, "Custom"] }, "confirmationStatus" => "confirmed" }

  # THE REGRESSION for the concurrency half. Two objects over ONE row is how a
  # double-click reaches the controller; the database, not Ruby, decides.
  test "only one caller can claim a row for broadcast" do
    tx = ptx
    rival = PendingTransaction.find(tx.id)

    assert tx.claim_for_broadcast!("SIG_A"), "the first caller wins the right to broadcast"
    assert_not rival.claim_for_broadcast!("SIG_B"), "the second caller must lose it"
    assert_equal "submitted", rival.status, "and must see the state the row is ACTUALLY in"
    assert_equal "SIG_A", rival.tx_signature, "the winner's signature is the one on the row"
  end

  # THE PROPERTY THE WHOLE FIX RESTS ON. A claimed row always names its
  # transaction, so there is always something to ask the chain about.
  test "a claim records the signature and the anchor in the same statement" do
    tx = ptx
    freeze_time do
      assert tx.claim_for_broadcast!("SIG_ABOUT_TO_GO_OUT")

      assert_equal "submitted", tx.status
      assert_equal "SIG_ABOUT_TO_GO_OUT", tx.tx_signature
      assert_equal Time.current, tx.broadcast_at, "broadcast_at anchors the never-landed verdict"
    end
    assert_not tx.awaiting_reconciliation?,
               "a claim can no longer produce the signature-less state at all"
    assert tx.awaiting_broadcast_verdict?
  end

  test "a claim refuses to take the row without naming a signature" do
    tx = ptx
    assert_raises(ArgumentError) { tx.claim_for_broadcast!(nil) }
    assert tx.reload.pending?, "a refused claim leaves the row alone"
  end

  test "a rewind after a provably un-sent failure makes the row claimable again" do
    tx = ptx
    tx.claim_for_broadcast!("SIG_NEVER_SENT")

    assert tx.rewind_broadcast!("SIG_NEVER_SENT")
    assert tx.pending?, "a transaction that never left the server stays retryable"
    assert_nil tx.tx_signature, "and carries no dead signature into the next attempt"
    assert_nil tx.broadcast_at, "nor a stale anchor that would age the next send"
    assert tx.claim_for_broadcast!("SIG_SECOND_ATTEMPT")
  end

  # THE SECOND LINE. A rewind names the signature it is clearing, so it can
  # never act on a row that has moved on since the caller read it.
  test "a rewind cannot clear a signature it did not name" do
    tx = ptx
    tx.claim_for_broadcast!("SIG_THAT_LANDED")

    assert_not tx.rewind_broadcast!("SOME_OTHER_SIG")

    assert_equal "SIG_THAT_LANDED", tx.reload.tx_signature
    assert_equal "submitted", tx.status
    assert_not tx.pending?, "a landed transaction must never become re-broadcastable"
  end

  # ── THE FOUR-WAY VERDICT ───────────────────────────────────────────────────
  #
  # This is the door that replaces reading an exception. Its :ambiguous branch
  # is the one that matters: a rewind there is a double-send.

  test "reconcile leaves a landed row for the caller to verify" do
    tx = ptx
    tx.claim_for_broadcast!("SIG_LANDED")

    assert_equal :landed, tx.reconcile_broadcast!(landed_status)
    assert_equal "submitted", tx.reload.status, "reconcile must not confirm without the signer set"
    assert_equal "SIG_LANDED", tx.tx_signature
  end

  # THE CASE #confirm CANNOT RECORD. Solana::TxVerifier refuses anything
  # carrying meta.err, so a transaction that landed and FAILED has no other way
  # back — before this it was a Rails console.
  test "reconcile rewinds a transaction that landed and failed" do
    tx = ptx
    tx.claim_for_broadcast!("SIG_FAILED")

    assert_equal :failed, tx.reconcile_broadcast!(failed_status)
    assert tx.reload.pending?, "the treasury did not move, so the row can be rebuilt"
    assert_nil tx.tx_signature
  end

  test "reconcile rewinds a transaction the chain never saw, once its blockhash lapsed" do
    tx = ptx
    tx.claim_for_broadcast!("SIG_DEAD")
    tx.update_columns(broadcast_at: (OnchainSendVerdict::BLOCKHASH_LAPSE + 1.minute).ago)

    assert_equal :never_landed, tx.reconcile_broadcast!(nil)
    assert tx.reload.pending?
    assert_nil tx.tx_signature
  end

  # THE TRAP THE VERDICT EXISTS TO CLOSE. "No row" is NOT "never landed" — an
  # absent status also means in-flight and not-yet-indexed, and it means that
  # for the whole blockhash window. Rewinding here double-sends the treasury.
  test "reconcile changes NOTHING while the transaction can still land" do
    tx = ptx
    tx.claim_for_broadcast!("SIG_IN_FLIGHT")

    assert_equal :ambiguous, tx.reconcile_broadcast!(nil)

    assert_equal "submitted", tx.reload.status, "an unresolved row must stay claimed"
    assert_equal "SIG_IN_FLIGHT", tx.tx_signature
    assert_not tx.pending?, "and must not become rebuildable"
  end

  # A row with no anchor is AMBIGUOUS, never verified-dead — the legacy rows
  # claimed before broadcast_at existed must not be rewound on a missing status.
  test "reconcile refuses to call an unanchored row dead" do
    tx = ptx
    tx.claim_for_broadcast!("SIG_NO_ANCHOR")
    tx.update_columns(broadcast_at: nil)

    assert_equal :ambiguous, tx.reconcile_broadcast!(nil)
    assert_equal "submitted", tx.reload.status
  end

  # LEGACY ONLY. Rows claimed by the older code carry no signature and no handle
  # to ask the chain with; they are still reconciled by hand through #confirm.
  test "awaiting_reconciliation? still names a legacy claimed row whose answer was lost" do
    tx = ptx
    assert_not tx.awaiting_reconciliation?, "an unclaimed row is not stranded"

    tx.update_columns(status: "submitted", tx_signature: nil)
    assert tx.awaiting_reconciliation?, "claimed, no signature — the wire may be on chain"
    assert_not tx.awaiting_broadcast_verdict?, "and it has nothing to reconcile WITH"
  end
end
