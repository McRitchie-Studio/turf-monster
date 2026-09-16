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
    assert_equal "FAKE_SIG_SIGNED_WIRE", tx.tx_signature,
                 "the transaction landed, so the row must carry its signature even though verify failed"
    assert_not tx.pending?, "a landed transaction must not be left re-broadcastable"
    assert_match(/recorded on this row/, JSON.parse(response.body)["error"],
                 "the operator must be told the money moved, not that nothing happened")

    # THE SECOND SEND — the actual loss. One settle paid; one settle unreconciled.
    with_vault(vault, verifier: ->(**) { true }) { broadcast(tx) }

    assert_equal 1, vault.broadcast_calls.length, "the wire must never go out twice"
    assert_response :unprocessable_entity
  end

  # THE SAME PROPERTY, ISOLATED from the stamp so a regression in either half
  # names itself. A row whose broadcast already went out is not a draft.
  test "a row that already put a wire on the chain refuses a second one" do
    tx = ptx
    vault = FakeVault.new
    flake = ->(**) { raise Solana::TxVerifier::VerificationError, "RPC lagged" }

    with_vault(vault, verifier: flake) { broadcast(tx) }
    with_vault(vault, verifier: ->(**) { true }) { broadcast(tx, wire: "A_SECOND_WIRE") }

    # THE MONEY ASSERTION FIRST. A response-code assertion above it trips before
    # this one and reports a status mismatch, which reads like a routing problem
    # rather than "a second settlement went out".
    assert_equal ["SIGNED_WIRE"], vault.broadcast_calls,
                 "a second, DIFFERENT wire is a second settlement — the loss this task exists to stop"
    assert_response :unprocessable_entity
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
    assert tx.awaiting_broadcast_verdict?,
           "the wire may be on chain, so the row must stay claimed rather than invite a second send"
    assert_not tx.pending?
    assert_equal "FAKE_SIG_SIGNED_WIRE", tx.tx_signature,
                 "and it must NAME the transaction, so the chain can be asked what became of it"

    second = FakeVault.new
    with_vault(second, verifier: ->(**) { true }) { broadcast(tx, wire: "A_SECOND_WIRE") }

    assert_empty second.broadcast_calls, "an ambiguous answer is never a licence to re-send"
    assert_response :unprocessable_entity
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
    # A LEGACY row: claimed by the older code, which stamped from the RPC's
    # reply and so left nothing behind when that reply was lost. A claim cannot
    # produce this state any more.
    tx.update_columns(status: "submitted", tx_signature: nil)
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
    tx.update_columns(status: "submitted", tx_signature: nil)
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
    assert_equal "FAKE_SIG_SIGNED_WIRE", tx.reload.tx_signature

    Solana::Vault.stub :new, FakeVault.new do
      get admin_pending_transactions_path
    end

    assert_response :success
    assert_match(/Broadcast · unreconciled/, response.body)
    assert_match(/outcome is not yet\s+established/, response.body)
    assert_match(/Reconcile/, response.body,
                 "and it must offer the READ that settles the row, not just a warning")
    assert_no_match(/collectExtraCosigners\(this\)/, response.body,
                    "a row that has broadcast must not offer a Co-sign button")
  end

  test "a row whose broadcast answer was lost is labelled differently from one that landed" do
    tx = ptx
    tx.update_columns(status: "submitted", tx_signature: nil)

    Solana::Vault.stub :new, FakeVault.new do
      get admin_pending_transactions_path
    end

    assert_response :success
    assert_match(/Broadcast · result unknown/, response.body)
    assert_match(/may be on chain/, response.body)
    assert_match(/would send a SECOND transaction/, response.body)
  end
  # ══════════════════════════════════════════════════════════════════════════
  # THE BLOCKER: THE NODE'S OWN PRE-FLIGHT REFUSAL
  # ══════════════════════════════════════════════════════════════════════════
  #
  # `send_and_confirm` runs `skipPreflight: false`, so the NODE checks the real
  # blockhash and the real signatures — the two things the simulation above
  # deliberately skips — and refuses with a CODED JSON-RPC error without
  # forwarding. It is the LIKELY failure on this surface, not an edge: a
  # blockhash lives ~60-90s and the flow is rebuild → render → open Phantom →
  # read a treasury settle → approve twice → POST.
  #
  # It is NOT typed `PreflightRejected`, and it must not be: Solana::Client#call
  # retries the faults that mean "the answer was lost" and surfaces only the
  # last one, so a coded error can be the second answer to a wire the first
  # attempt already forwarded. Rewinding on it re-sends the treasury.
  #
  # So the row stays claimed — and the whole point of the fix is that staying
  # claimed is no longer a dead end.
  test "the node's own pre-flight refusal leaves a row that can still be recovered" do
    tx = ptx
    refused = Solana::Client::RpcError.new("Blockhash not found", code: -32002)
    vault = FakeVault.new(broadcast_raises: refused)

    with_vault(vault, verifier: ->(**) { true }) { broadcast(tx) }

    tx.reload
    assert_not tx.pending?, "the answer is not a proof, so the claim is NOT given back"
    assert_equal "FAKE_SIG_SIGNED_WIRE", tx.tx_signature,
                 "but the row names its transaction, which is what keeps it recoverable"
    assert tx.awaiting_broadcast_verdict?
    assert_not tx.awaiting_reconciliation?,
               "it is NOT the old signature-less state — that one had no way back"
  end

  # THE OTHER HALF OF THE BLOCKER, and the one that was a Rails console: the row
  # above must actually get out. Nothing landed and the blockhash window has
  # lapsed, so the chain PROVES it can never land.
  test "reconcile frees a row whose wire the node refused, once its blockhash lapsed" do
    tx = ptx
    vault = FakeVault.new(broadcast_raises: Solana::Client::RpcError.new("Blockhash not found", code: -32002))
    with_vault(vault, verifier: ->(**) { true }) { broadcast(tx) }

    # The window has to have lapsed — inside it the honest answer is "wait".
    tx.reload.update_columns(broadcast_at: (OnchainSendVerdict::BLOCKHASH_LAPSE + 1.minute).ago)

    # signature_statuses is empty, so the chain has never heard of it.
    Solana::Vault.stub :new, FakeVault.new do
      post reconcile_admin_pending_transaction_path(slug: tx.slug), as: :json
    end

    assert_response :success
    tx.reload
    assert tx.pending?, "verified-dead, so the operator can rebuild — not a console job"
    assert_nil tx.tx_signature
    assert_nil tx.broadcast_at, "and the next attempt gets its own anchor"
  end

  # THE TRAP INSIDE THE DOOR. An absent status means "in flight" as well as
  # "never landed", and it means that for the whole blockhash window. Rewinding
  # here is the double-send the claim exists to stop.
  test "reconcile changes nothing while the transaction can still land" do
    tx = ptx
    vault = FakeVault.new(broadcast_raises: RuntimeError.new("connection reset while sending"))
    with_vault(vault, verifier: ->(**) { true }) { broadcast(tx) }

    Solana::Vault.stub :new, FakeVault.new do
      post reconcile_admin_pending_transaction_path(slug: tx.slug), as: :json
    end

    assert_response :success
    tx.reload
    assert_not tx.pending?, "an unresolved row must not become rebuildable"
    assert_equal "FAKE_SIG_SIGNED_WIRE", tx.tx_signature

    second = FakeVault.new
    with_vault(second, verifier: ->(**) { true }) { broadcast(tx, wire: "A_SECOND_WIRE") }
    assert_empty second.broadcast_calls, "and a reconcile that resolved nothing is not a licence to re-send"
  end

  # THE CASE #confirm CANNOT RECORD AT ALL. Solana::TxVerifier refuses anything
  # carrying meta.err (tx_verifier.rb), which is right for recording an
  # authorisation and useless for recording a definitive failure — so a
  # transaction that LANDED AND FAILED had no door before this one.
  test "reconcile frees a transaction that landed and FAILED on chain" do
    tx = ptx
    vault = FakeVault.new(broadcast_raises: RuntimeError.new("Transaction failed: InstructionError"))
    with_vault(vault, verifier: ->(**) { true }) { broadcast(tx) }

    failed = { "err" => { "InstructionError" => [0, { "Custom" => 6046 }] },
               "confirmationStatus" => "confirmed" }
    Solana::Vault.stub :new, FakeVault.new(signature_statuses: { "FAKE_SIG_SIGNED_WIRE" => failed }) do
      post reconcile_admin_pending_transaction_path(slug: tx.slug), as: :json
    end

    assert_response :success
    tx.reload
    assert tx.pending?, "the treasury did not move, so the row must be rebuildable"
    assert_nil tx.tx_signature
  end

  # A LANDED row is NOT confirmed here. Reconcile has no signer set, and
  # flipping treasury state on a bare status read would skip OPSEC-010/011.
  test "reconcile refuses to confirm a landed row on its own" do
    tx = ptx
    vault = FakeVault.new(broadcast_raises: RuntimeError.new("confirmation timeout"))
    with_vault(vault, verifier: ->(**) { true }) { broadcast(tx) }

    landed = { "err" => nil, "confirmationStatus" => "finalized" }
    Solana::Vault.stub :new, FakeVault.new(signature_statuses: { "FAKE_SIG_SIGNED_WIRE" => landed }) do
      post reconcile_admin_pending_transaction_path(slug: tx.slug), as: :json
    end

    assert_response :success
    tx.reload
    assert_equal "submitted", tx.status, "verification is still owed before the row is confirmed"
    assert_equal "FAKE_SIG_SIGNED_WIRE", tx.tx_signature
    assert_match(/LANDED/, JSON.parse(response.body)["message"])
  end

  # ══════════════════════════════════════════════════════════════════════════
  # NOTHING THAT CAN RAISE WITHOUT SENDING MAY SIT INSIDE THE CLAIM
  # ══════════════════════════════════════════════════════════════════════════
  #
  # `Solana::Vault.new` validates its RPC URL and decodes keypairs in its
  # constructor. None of those failures is `PreflightRejected`, so before the
  # vault was hoisted above the claim they stranded the row — a claim taken for
  # a wire that provably never existed.
  test "a vault that cannot even be constructed strands no claim" do
    tx = ptx
    boom = -> { raise Solana::Client::InsecureRpcUrlError, "http:// RPC URL refused" }

    Solana::Vault.stub :new, boom do
      broadcast(tx)
    end

    assert_response :unprocessable_entity
    assert tx.reload.pending?, "nothing was sent and nothing could be, so the row stays retryable"
    assert_nil tx.tx_signature
  end

  # THE SAME RULE FOR THE WIRE ITSELF: a payload whose signature cannot be read
  # is refused BEFORE the claim, not after it.
  test "a wire too short to carry a signature is refused before the claim" do
    tx = ptx
    vault = FakeVault.new(signature_for_wire_raises: RuntimeError.new("wire too short to carry a signature"))

    with_vault(vault, verifier: ->(**) { true }) { broadcast(tx) }

    assert_response :unprocessable_entity
    assert_empty vault.broadcast_calls
    assert tx.reload.pending?
    assert_nil tx.tx_signature
  end

  # ══════════════════════════════════════════════════════════════════════════
  # #rebuild MAY NOT UN-CLAIM A ROW
  # ══════════════════════════════════════════════════════════════════════════
  #
  # It read `pending?` and then wrote `status: "pending"` unconditionally, so a
  # #broadcast that claimed the row in between was silently un-claimed — the
  # last path that could hand a second caller a row whose wire is going out.
  test "rebuild refuses a row that was claimed after its own guard read" do
    tx = ptx
    tx.claim_for_broadcast!("SIG_ALREADY_GOING_OUT")

    Solana::Vault.stub :new, FakeVault.new do
      post rebuild_admin_pending_transaction_path(slug: tx.slug), as: :json
    end

    tx.reload
    assert_equal "submitted", tx.status, "a claimed row must not be rebuilt back to pending"
    assert_equal "SIG_ALREADY_GOING_OUT", tx.tx_signature
  end
end
