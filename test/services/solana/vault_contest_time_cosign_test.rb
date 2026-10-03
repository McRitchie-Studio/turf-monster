require "test_helper"

# THE CONTEST LOCK IS BROADCAST BY THE SERVER (server-broadcasts-contest-lock).
#
# THE DEFECT, 2026-10-03, production. Admin contest edit -> "Set lock time with
# Phantom" died with `403 : {"jsonrpc":"2.0","error":{"code": 403, "message":
# "Access forbidden"}}`. lock_contest.js broadcast from the browser through
# `document.body.dataset.solanaRpcUrl`, which on mainnet falls back to the free
# public RPC (the credentialed SOLANA_RPC_URL is never handed to a page), and
# that RPC refuses browser traffic. cosign.js fixed the same defect on
# 2026-09-05.
#
# THE FIX. Phantom signs a wire the server built with the fee payer's slot
# EMPTY; the confirm endpoint hands it to Vault#cosign_and_broadcast_contest_time
# (the gem's Cosign::Completer, the rail the entry and contest-create cosigns
# ride), judged against Vault#contest_time_expectation — REBUILT from the
# contest slug, the timestamp and the operator's wallet. These tests pin:
#
#   1. the builder's own wire is admitted, signed by the house, simulated,
#      broadcast over the SERVER's client, and confirmed;
#   2. a tampered or foreign wire (other contest, other timestamp, other
#      instruction, other signer) is refused BEFORE the house signs or anything
#      is sent — the endpoint cannot be made to broadcast arbitrary bytes;
#   3. a program refusal comes back as SimulationFailed carrying the program's
#      own logs, and nothing is sent.
class Solana::VaultContestTimeCosignTest < ActiveSupport::TestCase
  SLUG = "contest-time-cosign-test".freeze
  LOCK_TS = 1_800_000_000

  # Records every RPC the completer makes, on top of the blockhash the builder
  # needs. `simulate_err` / `simulate_logs` make the PROGRAM refuse.
  class RecordingRpc
    attr_reader :journal, :sent_wires

    def initialize(simulate_err: nil, simulate_logs: [])
      @journal = []
      @sent_wires = []
      @simulate_err = simulate_err
      @simulate_logs = simulate_logs
      CosignFakeClient.teach(self)
      @blockhash = Solana::Keypair.generate.to_base58
    end

    def get_latest_blockhash(**_opts)
      @blockhash
    end

    def get_block_height(commitment: nil)
      @journal << :get_block_height
      1
    end

    def simulate_transaction(_wire, **_opts)
      @journal << :simulate
      { "err" => @simulate_err, "logs" => @simulate_logs }
    end

    def send_transaction(wire, **_opts)
      @journal << :send
      @sent_wires << wire
      nil
    end

    def confirm_transaction(_signature)
      @journal << :confirm
      { "value" => [{ "err" => nil, "confirmationStatus" => "confirmed" }] }
    end
  end

  def setup
    @operator = Solana::Keypair.generate # the admin's Phantom wallet (a vault signer)
    @rpc = RecordingRpc.new
    @vault = Solana::Vault.new(client: @rpc)
    # The completer polls confirmation after a 1s sleep; skip the wait.
    @vault.define_singleton_method(:cosign_completer) do
      Solana::Cosign::Completer.new(client: client, fee_payer: Solana::Keypair.admin,
                                    poll_interval: 0, sleeper: ->(_s) { })
    end
  end

  # What Phantom does: fill ONLY the operator's slot, leave the house's empty.
  def phantom_sign(wire, signer: @operator)
    Solana::Transaction.cosign_wire_base64(wire, signer: signer, require_complete: false)
  end

  def lock_expectation(ts: LOCK_TS, slug: SLUG, admin: @operator.address)
    @vault.contest_time_expectation("set_contest_lock_time", slug, ts, admin_pubkey: admin)
  end

  def broadcast(wire, expectation)
    @vault.cosign_and_broadcast_contest_time(wire, expectation: expectation)
  end

  # --- 1. the happy path: the server broadcasts what it built ----------------

  test "the builder leaves the house's slot empty for the server to fill after Phantom" do
    built = @vault.build_set_contest_lock_time(SLUG, LOCK_TS, admin_pubkey: @operator.address)
    message = Solana::WireMessage.parse(Base64.strict_decode64(built[:serialized_tx]))

    assert message.signature_slot_empty?(0),
           "a pre-signed fee payer slot would mean the browser holds a broadcastable wire — " \
           "the house signs only after the server has judged what Phantom returned"
    assert_kind_of Integer, built[:last_valid_block_height]
  end

  test "a Phantom-signed lock wire is admitted, house-signed, simulated, broadcast and confirmed" do
    built = @vault.build_set_contest_lock_time(SLUG, LOCK_TS, admin_pubkey: @operator.address)
    signed = phantom_sign(built[:serialized_tx])

    signature = broadcast(signed, lock_expectation)

    assert_equal %i[simulate send confirm], @rpc.journal - [:get_block_height],
                 "simulate before send, confirm after"
    assert_equal 1, @rpc.sent_wires.length, "exactly one broadcast, over the SERVER's client"
    sent = Solana::WireMessage.parse(Base64.strict_decode64(@rpc.sent_wires.first))
    refute sent.signature_slot_empty?(0), "the house filled the fee payer's slot before sending"
    assert_equal @vault.signature_for_wire(@rpc.sent_wires.first), signature
  end

  test "clearing the lock (timestamp 0) is the same flow and is admitted" do
    built = @vault.build_set_contest_lock_time(SLUG, 0, admin_pubkey: @operator.address)
    broadcast(phantom_sign(built[:serialized_tx]), lock_expectation(ts: 0))

    assert_equal 1, @rpc.sent_wires.length
  end

  test "the conclusion setter rides the same rail" do
    built = @vault.build_set_contest_conclusion_time(SLUG, LOCK_TS, admin_pubkey: @operator.address)
    expectation = @vault.contest_time_expectation("set_contest_conclusion_time", SLUG, LOCK_TS,
                                                  admin_pubkey: @operator.address)
    broadcast(phantom_sign(built[:serialized_tx]), expectation)

    assert_equal 1, @rpc.sent_wires.length
  end

  # --- 2. tampered / foreign wires are refused before anything is signed -----

  def assert_refused_unsent(wire, expectation, reason_pattern)
    error = assert_raises(Solana::Cosign::WireRejected) { broadcast(wire, expectation) }
    assert_match reason_pattern, error.reason
    assert_empty @rpc.sent_wires, "a refused wire must never reach the chain"
    refute_includes @rpc.journal, :simulate, "refused before the house signed — not even simulated"
  end

  test "a wire whose TIMESTAMP differs from the one being confirmed is refused" do
    built = @vault.build_set_contest_lock_time(SLUG, LOCK_TS + 3600, admin_pubkey: @operator.address)
    assert_refused_unsent(phantom_sign(built[:serialized_tx]), lock_expectation, /instruction_data_mismatch/)
  end

  test "a wire for a DIFFERENT contest is refused" do
    built = @vault.build_set_contest_lock_time("#{SLUG}-elsewhere", LOCK_TS, admin_pubkey: @operator.address)
    assert_refused_unsent(phantom_sign(built[:serialized_tx]), lock_expectation, /instruction_accounts_mismatch/)
  end

  test "a CONCLUSION wire cannot be confirmed as a LOCK" do
    built = @vault.build_set_contest_conclusion_time(SLUG, LOCK_TS, admin_pubkey: @operator.address)
    assert_refused_unsent(phantom_sign(built[:serialized_tx]), lock_expectation, /instruction_data_mismatch/)
  end

  test "a wire signed by a wallet other than the session's operator is refused" do
    stranger = Solana::Keypair.generate
    built = @vault.build_set_contest_lock_time(SLUG, LOCK_TS, admin_pubkey: stranger.address)
    assert_refused_unsent(phantom_sign(built[:serialized_tx], signer: stranger), lock_expectation, /signer|account|mismatch/)
  end

  test "arbitrary bytes are refused" do
    junk = Base64.strict_encode64(SecureRandom.random_bytes(200))
    assert_refused_unsent(junk, lock_expectation, /unparseable|signer|mismatch|fee_payer/)
  end

  test "an UNSIGNED wire (Phantom never signed) is refused" do
    built = @vault.build_set_contest_lock_time(SLUG, LOCK_TS, admin_pubkey: @operator.address)
    assert_refused_unsent(built[:serialized_tx], lock_expectation, /signature_missing/)
  end

  # --- 3. the program's own error ---------------------------------------------

  test "a program refusal surfaces as SimulationFailed with the program's logs, and nothing is sent" do
    logs = ["Program log: AnchorError occurred. Error Code: ContestAlreadySettled. Error Number: 6006."]
    @rpc = RecordingRpc.new(simulate_err: { "InstructionError" => [2, { "Custom" => 6006 }] }, simulate_logs: logs)
    @vault = Solana::Vault.new(client: @rpc)

    built = @vault.build_set_contest_lock_time(SLUG, LOCK_TS, admin_pubkey: @operator.address)
    error = assert_raises(Solana::Cosign::SimulationFailed) do
      broadcast(phantom_sign(built[:serialized_tx]), lock_expectation)
    end

    assert_match(/6006/, error.message)
    assert_equal logs, error.logs
    assert_empty @rpc.sent_wires
  end
end
