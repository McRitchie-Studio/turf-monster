require "test_helper"

# Solana::Vault#preflight_cosigned_wire! — the simulation a cosigned wire must
# pass before the house hands it to a browser to broadcast.
#
# WHY IT EXISTS. Cdp::OfframpSendsController#cosign fills the house's fee-payer
# signature on a player's Phantom-signed cash-out wire and RETURNS the bytes;
# the browser broadcasts them with `skipPreflight: true`
# (app/javascript/cdp_offramp_send.js). Nothing between the house signing and
# the chain executing asked whether the wire would fail — and a wire that fails
# on chain still charges its fee payer, which is the house. The entry and
# contest-create cosign paths simulate before they broadcast; this is the same
# check for the path that does not broadcast itself.
#
# It runs with the SAME settings as Vault#cosign_and_broadcast_entry and
# #simulate_and_broadcast (sig_verify:false + replace_recent_blockhash:true):
# the house pays for EXECUTED transactions, and a wire with a bad signature or
# a dead blockhash is never executed, so the program verdict is the one that
# protects the fee payer.
class Solana::VaultPreflightCosignedWireTest < ActiveSupport::TestCase
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

    def send_transaction(wire, **_opts)
      @sent << wire
      "SIG_#{wire}"
    end
  end

  def vault_with(client)
    vault = Solana::Vault.allocate
    vault.instance_variable_set(:@client, client)
    vault
  end

  test "passes a wire whose simulation is clean, and never sends it" do
    client = StubClient.new({ "err" => nil, "logs" => ["Program log: Instruction: Transfer"] })

    assert vault_with(client).preflight_cosigned_wire!("COSIGNED_WIRE")

    assert_equal ["COSIGNED_WIRE"], client.simulate_calls.map { |c| c[:wire] },
                 "the simulation must run on the exact cosigned bytes the caller will return"
    assert_empty client.sent, "a pre-flight only asks — the caller decides whether the bytes leave"
  end

  test "simulates with sig_verify off and a replaced blockhash, like the entry path" do
    client = StubClient.new({ "err" => nil })
    vault_with(client).preflight_cosigned_wire!("COSIGNED_WIRE")

    opts = client.simulate_calls.first[:opts]
    assert_equal false, opts[:sig_verify]
    assert_equal true,  opts[:replace_recent_blockhash]
  end

  test "a failing simulation raises PreflightRejected carrying the program error" do
    client = StubClient.new({
      "err" => { "InstructionError" => [2, { "Custom" => 1 }] },
      "logs" => ["Program log: Instruction: Transfer", "Program log: Error: insufficient funds"]
    })

    error = assert_raises(Solana::Vault::PreflightRejected) do
      vault_with(client).preflight_cosigned_wire!("COSIGNED_WIRE")
    end

    assert_match(/InstructionError/, error.message)
    assert_match(/insufficient funds/, error.message, "the logs travel with the error for the ErrorLog")
    assert_empty client.sent
  end

  test "a simulation that cannot be run refuses rather than passing the wire" do
    client = StubClient.new(raises: Solana::Client::RpcError.new("429 Too Many Requests"))

    error = assert_raises(Solana::Vault::PreflightRejected) do
      vault_with(client).preflight_cosigned_wire!("COSIGNED_WIRE")
    end

    assert_match(/could not be run/, error.message)
    assert_match(/429/, error.message)
  end

  # The browser broadcasts this wire with skipPreflight:true, so no node will
  # pre-flight it after us. An empty answer is not a pass.
  test "an empty simulation answer refuses — this is the wire's only pre-flight" do
    client = StubClient.new(nil)

    error = assert_raises(Solana::Vault::PreflightRejected) do
      vault_with(client).preflight_cosigned_wire!("COSIGNED_WIRE")
    end

    assert_match(/no result/, error.message)
  end

  # ── AN ANSWER WITH NO VERDICT IS NOT A PASS (cap-cashout-failed-send-rearms) ─
  #
  # The old check was `sim["err"]`, which reads a MISSING key exactly like a
  # clean `"err": null`. Every conforming node sends the key: agave's
  # RpcSimulateTransactionResult serializes `err: Option<…>` with no
  # skip_serializing_if, and read-only simulateTransaction calls against both
  # Helius and the public mainnet RPC on 2026-09-17 returned `"err": null` on a
  # clean simulation and `"err": "AccountNotFound"` on a failing one. So this
  # refusal never fires on a real answer; it exists so a proxy, a truncated
  # body or a future shape change cannot read as the house's go-ahead.

  test "an answer missing its err field refuses rather than passing the wire" do
    client = StubClient.new({ "logs" => ["Program log: Instruction: Transfer"], "unitsConsumed" => 1714 })

    error = assert_raises(Solana::Vault::PreflightUnavailable) do
      vault_with(client).preflight_cosigned_wire!("COSIGNED_WIRE")
    end

    assert_match(/no err field/, error.message)
  end

  test "an answer that is not an object refuses rather than passing the wire" do
    ["unexpected", [], 0].each do |answer|
      error = assert_raises(Solana::Vault::PreflightUnavailable, answer.inspect) do
        vault_with(StubClient.new(answer)).preflight_cosigned_wire!("COSIGNED_WIRE")
      end
      assert_match(/no err field/, error.message)
    end
  end

  # ── "TRY AGAIN" IS NOT "CHECK YOUR WALLET" ──────────────────────────────────
  #
  # A simulation that could not give a verdict says nothing about the wire, so
  # the player is told to retry. A program refusal is about the wire, so they
  # are told to look at their wallet. The controller can only word those
  # differently if the two arrive as different types.

  test "a simulation that could not be run is typed unavailable" do
    client = StubClient.new(raises: Solana::Client::RpcError.new("Network error: execution expired"))

    error = assert_raises(Solana::Vault::PreflightUnavailable) do
      vault_with(client).preflight_cosigned_wire!("COSIGNED_WIRE")
    end
    assert_equal "Pre-flight simulation could not be run: Network error: execution expired", error.message
  end

  test "an empty answer is typed unavailable" do
    assert_raises(Solana::Vault::PreflightUnavailable) do
      vault_with(StubClient.new(nil)).preflight_cosigned_wire!("COSIGNED_WIRE")
    end
  end

  test "a program refusal is typed rejected and NOT unavailable" do
    client = StubClient.new({ "err" => { "InstructionError" => [2, { "Custom" => 6001 }] } })

    error = assert_raises(Solana::Vault::PreflightRejected) do
      vault_with(client).preflight_cosigned_wire!("COSIGNED_WIRE")
    end
    assert_not_kind_of Solana::Vault::PreflightUnavailable, error,
                       "a failed simulation is about the wire — telling the player to just retry would be wrong"
  end

  # Every existing `rescue PreflightRejected` must still catch the new type.
  test "unavailable is a kind of rejected" do
    assert_operator Solana::Vault::PreflightUnavailable, :<, Solana::Vault::PreflightRejected
  end
end
