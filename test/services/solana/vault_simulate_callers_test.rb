require "test_helper"

# THE FOUR CALLERS OF THE ONE SIMULATE-AND-READ-ERR BLOCK.
#
# Solana::Vault used to carry four inline copies of "simulate this wire, then
# read its err": #cosign_and_broadcast_entry, #cosign_and_broadcast_create_contest,
# #simulate_and_broadcast and #preflight_cosigned_wire!. They differ on purpose,
# and cap-cashout-failed-send-rearms folded them into one private helper
# (#simulate_wire!) without changing what any caller does.
#
# These tests were written and run GREEN against the four inline copies BEFORE
# the helper existed, so they pin each caller's behaviour as it was, not as the
# helper happens to implement it. Every difference between the callers is a
# row below:
#
#   caller                       | raises on err       | message prefix               | call raises       | nil / no-err answer
#   cosign_and_broadcast_entry   | RuntimeError        | "Entry pre-flight"           | propagates as-is  | passes, broadcasts
#   cosign_and_broadcast_create… | RuntimeError        | "Contest-create pre-flight"  | propagates as-is  | passes, broadcasts
#   simulate_and_broadcast       | PreflightRejected   | "Pre-flight"                 | PreflightRejected | passes, broadcasts
#   preflight_cosigned_wire!     | PreflightRejected   | "Pre-flight"                 | …Unavailable      | REFUSES (…Unavailable)
#
# The broadcasting callers may pass an empty answer because the node
# pre-flights their own send. The cash-out wire is broadcast by a browser with
# skipPreflight:true, so nothing checks it after the house — it alone fails
# closed.
class Solana::VaultSimulateCallersTest < ActiveSupport::TestCase
  class StubClient
    attr_reader :simulate_calls, :sent

    def initialize(sim_result = nil, raises: nil)
      @sim_result = sim_result
      @raises = raises
      @simulate_calls = []
      @sent = []
    end

    def simulate_transaction(wire, **opts)
      @simulate_calls << { wire: wire, opts: opts }
      raise @raises if @raises
      @sim_result
    end

    def send_and_confirm(wire)
      @sent << wire
      "SIG_#{wire}"
    end
  end

  EIGHT_LOGS = (1..8).map { |i| "Program log: line #{i}" }.freeze
  PROGRAM_ERR = { "InstructionError" => [1, { "Custom" => 6001 }] }.freeze

  def vault_with(client)
    vault = Solana::Vault.allocate
    vault.instance_variable_set(:@client, client)
    vault
  end

  # The two legacy broadcast paths fill the admin slot first. The cosign itself
  # is covered by entry_cosign_wire_test.rb; here it only needs to be visible,
  # so the tests can prove the simulation ran on the PATCHED bytes.
  def with_patched_cosign(&block)
    Solana::Transaction.stub(:cosign_wire_base64, ->(wire, **) { "PATCHED_#{wire}" }, &block)
  end

  def expected_failure(prefix)
    "#{prefix} simulation failed: #{PROGRAM_ERR.inspect}\n#{EIGHT_LOGS.last(6).join("\n")}"
  end

  # ── Settings: identical for all four ──────────────────────────────────────

  {
    cosign_and_broadcast_entry: "PATCHED_WIRE",
    cosign_and_broadcast_create_contest: "PATCHED_WIRE",
    simulate_and_broadcast: "WIRE",
    preflight_cosigned_wire!: "WIRE"
  }.each do |caller, simulated_wire|
    test "#{caller} simulates #{simulated_wire} with sig_verify off, a replaced blockhash, and the client's default commitment" do
      client = StubClient.new({ "err" => nil })
      with_patched_cosign { vault_with(client).public_send(caller, "WIRE") }

      assert_equal 1, client.simulate_calls.size
      call = client.simulate_calls.first
      assert_equal simulated_wire, call[:wire]
      assert_equal({ sig_verify: false, replace_recent_blockhash: true }, call[:opts],
                   "no caller passes a commitment, so the gem's own default stays in force")
    end
  end

  # ── A program refusal: class and exact message ────────────────────────────

  {
    cosign_and_broadcast_entry: ["Entry pre-flight", RuntimeError],
    cosign_and_broadcast_create_contest: ["Contest-create pre-flight", RuntimeError],
    simulate_and_broadcast: ["Pre-flight", Solana::Vault::PreflightRejected],
    preflight_cosigned_wire!: ["Pre-flight", Solana::Vault::PreflightRejected]
  }.each do |caller, (prefix, klass)|
    test "#{caller} refuses a program error as exactly #{klass.name}, keeping the last six log lines" do
      client = StubClient.new({ "err" => PROGRAM_ERR, "logs" => EIGHT_LOGS })

      error = assert_raises(RuntimeError) { with_patched_cosign { vault_with(client).public_send(caller, "WIRE") } }

      assert_instance_of klass, error
      assert_equal expected_failure(prefix), error.message
      assert_empty client.sent, "a refused simulation must never reach the chain"
    end
  end

  test "a program error with no logs carries no trailing newline, for every caller" do
    %i[cosign_and_broadcast_entry cosign_and_broadcast_create_contest
       simulate_and_broadcast preflight_cosigned_wire!].each do |caller|
      client = StubClient.new({ "err" => "AccountNotFound" })
      error = assert_raises(RuntimeError) { with_patched_cosign { vault_with(client).public_send(caller, "WIRE") } }
      assert_match(/simulation failed: "AccountNotFound"\z/, error.message, caller.to_s)
    end
  end

  # ── The simulation call itself raising ────────────────────────────────────

  %i[cosign_and_broadcast_entry cosign_and_broadcast_create_contest].each do |caller|
    test "#{caller} lets an unrunnable simulation's own exception through untyped" do
      rpc_error = Solana::Client::RpcError.new("429 Too Many Requests", code: 429)
      client = StubClient.new(raises: rpc_error)

      error = assert_raises(Solana::Client::RpcError) do
        with_patched_cosign { vault_with(client).public_send(caller, "WIRE") }
      end

      assert_same rpc_error, error
      assert_empty client.sent
    end
  end

  test "simulate_and_broadcast types an unrunnable simulation as exactly PreflightRejected" do
    client = StubClient.new(raises: Solana::Client::RpcError.new("429 Too Many Requests"))

    error = assert_raises(Solana::Vault::PreflightRejected) { vault_with(client).simulate_and_broadcast("WIRE") }

    assert_instance_of Solana::Vault::PreflightRejected, error
    assert_equal "Pre-flight simulation could not be run: 429 Too Many Requests", error.message
  end

  # ── An empty or err-less answer ───────────────────────────────────────────

  [nil, {}, { "logs" => ["Program log: no err key"] }].each do |answer|
    %i[cosign_and_broadcast_entry cosign_and_broadcast_create_contest simulate_and_broadcast].each do |caller|
      test "#{caller} lets a #{answer.inspect} answer through to its own node-preflighted send" do
        client = StubClient.new(answer)

        with_patched_cosign { vault_with(client).public_send(caller, "WIRE") }

        assert_equal 1, client.sent.size, "the node pre-flights this send, so the empty answer is not the last check"
      end
    end
  end
end
