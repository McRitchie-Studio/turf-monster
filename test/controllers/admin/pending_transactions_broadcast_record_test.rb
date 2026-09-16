require "test_helper"
require "minitest/mock"

# Admin::PendingTransactionsController#broadcast — WHEN THE SIGNATURE IS
# RECORDED, and what a second send would cost.
#
# ── THE DEFECT ────────────────────────────────────────────────────────────────
#
# The signature was stamped by `verify_and_record_cosign!`, i.e. AFTER
# `TxVerifier.verify!` had made one RPC call per claimed signer. A treasury
# transaction that LANDED and then hit an RPC hiccup during verification left
# the row `pending`, unsigned, and re-broadcastable: the money moved and the
# record said it did not. Nobody has to attack anything — an operator clicking
# Co-sign again, or any retry path, sends a second settle/sweep and only one of
# the two is ever reconciled.
#
# ── THE RULE, PORTED FROM THE CDP OFFRAMP ─────────────────────────────────────
#
# Never let a VERIFICATION step decide whether a broadcast happened. The
# broadcast happened when the wire went out. `Cdp::OfframpSendJob` persists its
# signature before the send and re-verifies rather than re-sending; the same
# reasoning killed `CdpRampTransaction#rearm_stalled_send!`'s nil-means-never-
# landed read. Here the wire is produced synchronously, so the anchor is the
# instant `simulate_and_broadcast` RETURNS.
#
# A verification failure then becomes an ALERT ON A RECORDED TRANSACTION rather
# than the absence of a record.
class Admin::PendingTransactionsBroadcastRecordTest < ActionDispatch::IntegrationTest
  setup do
    @admin   = users(:alex)
    @contest = contests(:one)
    @contest.update!(onchain_contest_id: "onchain_broadcast_record")
    log_in_as(@admin)
  end

  def ptx(tx_type = "settle_contest", metadata = { settlements: [] }, target: @contest)
    PendingTransaction.create!(
      tx_type: tx_type, serialized_tx: "OLD_TX", status: "pending",
      target: target, initiator_address: "init", metadata: metadata.to_json
    )
  end

  def cosigner = Solana::Config::MULTISIG_SIGNERS.first

  # `encode_base58` is stubbed because `writable_for_target` encodes a PDA; the
  # verifier itself is stubbed per-test, since WHEN it runs is the whole subject.
  def with_vault(vault, verifier:, &block)
    Solana::Vault.stub :new, vault do
      Solana::Keypair.stub :encode_base58, ->(k) { k.is_a?(String) ? k : k.to_s } do
        Solana::TxVerifier.stub(:verify!, verifier, &block)
      end
    end
  end

  def broadcast(tx, wire: "SIGNED_WIRE")
    post broadcast_admin_pending_transaction_path(slug: tx.slug),
         params: { cosigner_address: cosigner, signed_tx: wire }, as: :json
  end

  # ══════════════════════════════════════════════════════════════════════════
  # THE REGRESSION. Against the code this change replaces, both halves fail:
  # the row comes back with a nil tx_signature, and the second POST puts a
  # second wire on the chain.
  # ══════════════════════════════════════════════════════════════════════════
  test "a landed transaction whose verify flakes is RECORDED, and never re-broadcast" do
    tx = ptx
    vault = FakeVault.new
    flake = ->(**) { raise Solana::TxVerifier::VerificationError, "RPC lagged behind the commitment" }

    with_vault(vault, verifier: flake) { broadcast(tx) }

    assert_response :unprocessable_entity
    tx.reload
    assert_equal "FAKE_SIG_broadcast", tx.tx_signature,
                 "the transaction landed, so the row must carry its signature even though verify failed"
    assert_not tx.pending?, "a landed transaction must not be left re-broadcastable"
    assert_match(/recorded on this row/, JSON.parse(response.body)["error"],
                 "the operator must be told the money moved, not that nothing happened")

    # THE SECOND SEND — the actual loss. One settle paid; one settle unreconciled.
    with_vault(vault, verifier: ->(**) { true }) { broadcast(tx) }

    assert_response :unprocessable_entity
    assert_equal 1, vault.broadcast_calls.length, "the wire must never go out twice"
  end

  # THE SAME PROPERTY, ISOLATED from the stamp so a regression in either half
  # names itself. A row whose broadcast already went out is not a draft.
  test "a row that already put a wire on the chain refuses a second one" do
    tx = ptx
    vault = FakeVault.new
    flake = ->(**) { raise Solana::TxVerifier::VerificationError, "RPC lagged" }

    with_vault(vault, verifier: flake) { broadcast(tx) }
    with_vault(vault, verifier: ->(**) { true }) { broadcast(tx, wire: "A_SECOND_WIRE") }

    assert_response :unprocessable_entity
    assert_equal ["SIGNED_WIRE"], vault.broadcast_calls,
                 "a second, DIFFERENT wire is a second settlement — the loss this task exists to stop"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # THE OTHER HALF: the broadcast itself is not one-per-row either
  # ══════════════════════════════════════════════════════════════════════════
  #
  # Stamping on return closes the VERIFICATION window. It does not close the
  # BROADCAST window: `pending?` is a read, and two requests inside the
  # simulate+send round trips both pass it. The row is claimed before the wire
  # goes out, and given back only for a failure the vault PROVED happened first.

  test "a pre-flight refusal gives the claim back, so the row stays retryable" do
    tx = ptx
    # A seeded string is a PRE-FLIGHT refusal — see FakeVault#simulate_and_broadcast.
    vault = FakeVault.new(broadcast_raises: "Pre-flight simulation failed: SettlementOverflow")

    with_vault(vault, verifier: ->(**) { true }) { broadcast(tx) }

    assert_response :unprocessable_entity
    assert_match(/SettlementOverflow/, JSON.parse(response.body)["error"])
    tx.reload
    assert tx.pending?, "nothing left the server, so the operator must be able to rebuild and retry"
    assert_nil tx.tx_signature
  end

  test "an AMBIGUOUS failure after the send keeps the row claimed and unsigned" do
    tx = ptx
    # NOT a PreflightRejected: a fault raised once the bytes may already have
    # left is indistinguishable from one raised after they landed.
    vault = FakeVault.new(broadcast_raises: RuntimeError.new("connection reset while sending"))

    with_vault(vault, verifier: ->(**) { true }) { broadcast(tx) }

    assert_response :unprocessable_entity
    tx.reload
    assert tx.awaiting_reconciliation?,
           "the wire may be on chain, so the row must say so rather than invite a second send"
    assert_not tx.pending?

    second = FakeVault.new
    with_vault(second, verifier: ->(**) { true }) { broadcast(tx, wire: "A_SECOND_WIRE") }

    assert_response :unprocessable_entity
    assert_empty second.broadcast_calls, "an ambiguous answer is never a licence to re-send"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # THE RECONCILIATION DOOR
  # ══════════════════════════════════════════════════════════════════════════
  #
  # Closing the double-send window must not trade a loss of money for a
  # permanently stuck treasury row. #confirm accepts a row whose broadcast
  # answer was lost — and, because that signature is a CLIENT CLAIM rather than
  # one this server produced, it still proves it before writing.

  test "confirm records a signature found on chain for a stranded row" do
    tx = ptx
    tx.claim_for_broadcast!
    assert tx.awaiting_reconciliation?

    with_vault(FakeVault.new, verifier: ->(**) { true }) do
      post confirm_admin_pending_transaction_path(slug: tx.slug),
           params: { cosigner_address: cosigner, tx_signature: "FOUND_ON_CHAIN" }, as: :json
    end

    assert_response :success
    tx.reload
    assert_equal "confirmed", tx.status
    assert_equal "FOUND_ON_CHAIN", tx.tx_signature
  end

  # THE ASYMMETRY, PINNED. #broadcast records first because the SERVER produced
  # the signature; #confirm proves first because the CLIENT supplied it. A
  # future change that "tidies" the two into one order is what this notices.
  test "confirm stamps nothing when the claimed signature does not verify" do
    tx = ptx
    tx.claim_for_broadcast!
    flake = ->(**) { raise Solana::TxVerifier::VerificationError, "not that transaction" }

    with_vault(FakeVault.new, verifier: flake) do
      post confirm_admin_pending_transaction_path(slug: tx.slug),
           params: { cosigner_address: cosigner, tx_signature: "NOT_OUR_TX" }, as: :json
    end

    assert_response :unprocessable_entity
    assert_nil tx.reload.tx_signature,
               "an unverified client claim must never be stamped onto the row"
  end

  # ══════════════════════════════════════════════════════════════════════════
  # THE PAGE HAS TO SAY IT
  # ══════════════════════════════════════════════════════════════════════════
  #
  # Recording the signature is worth nothing if the treasury page renders the
  # row as a blank. `submitted` matched no branch in the status case, so a
  # landed-but-unverified transaction showed NO badge and NO control — an
  # unlabelled row that reads like a rendering bug rather than "the money moved".

  test "a landed-but-unverified row is labelled on the page, and offers no re-send" do
    tx = ptx

    # THE CONTROL. Without it the "no button" assertion below would pass on a
    # page that never renders a Co-sign button at all.
    Solana::Vault.stub :new, FakeVault.new do
      get admin_pending_transactions_path
    end
    assert_match(/collectExtraCosigners\(this\)/, response.body,
                 "a pending row DOES offer the button, so its absence below means something")

    flake = ->(**) { raise Solana::TxVerifier::VerificationError, "RPC lagged" }
    with_vault(FakeVault.new, verifier: flake) { broadcast(tx) }
    assert_equal "FAKE_SIG_broadcast", tx.reload.tx_signature

    Solana::Vault.stub :new, FakeVault.new do
      get admin_pending_transactions_path
    end

    assert_response :success
    assert_match(/Broadcast · unconfirmed/, response.body)
    assert_match(/only its verification did not/, response.body)
    assert_no_match(/collectExtraCosigners\(this\)/, response.body,
                    "a row that has broadcast must not offer a Co-sign button")
  end

  test "a row whose broadcast answer was lost is labelled differently from one that landed" do
    tx = ptx
    tx.claim_for_broadcast!

    Solana::Vault.stub :new, FakeVault.new do
      get admin_pending_transactions_path
    end

    assert_response :success
    assert_match(/Broadcast · result unknown/, response.body)
    assert_match(/may be on chain/, response.body)
    assert_match(/would send a SECOND transaction/, response.body)
  end
end
