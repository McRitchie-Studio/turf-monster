require "test_helper"

# THE CALLERS OF THE ONE SIMULATE-AND-READ-ERR BLOCK.
#
# Solana::Vault used to carry four inline copies of "simulate this wire, then
# read its err": #cosign_and_broadcast_entry, #cosign_and_broadcast_create_contest,
# #simulate_and_broadcast and #preflight_cosigned_wire!. They differ on purpose,
# and cap-cashout-failed-send-rearms folded them into one private helper
# (#simulate_wire!) without changing what any caller does.
#
# THERE ARE TWO CALLERS NOW, NOT FOUR. turf-adopts-cosign-primitives moved the
# two COSIGN paths onto `Solana::Cosign::Completer#complete`, which cosigns,
# checks the deadline, SIMULATES, records and sends inside the gem — so neither
# of them reaches #simulate_wire! any more. That is a deletion of two rows from
# the table below, and it is pinned three ways rather than simply dropped:
#
#   * the two surviving rows are still driven, end to end, below;
#   * "exactly these two methods call #simulate_wire!" is read off vault.rb's
#     own source, so a third caller added later fails here instead of quietly
#     joining an out-of-date table;
#   * the two that LEFT are driven too — through a stubbed completer, against a
#     client whose simulation would REFUSE — so "it does not simulate here" is a
#     measured fact and not an absence of evidence.
#
# These tests were written and run GREEN against the four inline copies BEFORE
# the helper existed, so the surviving rows pin each caller's behaviour as it
# was, not as the helper happens to implement it:
#
#   caller                     | raises on err             | message prefix | call raises          | nil / no-err answer
#   simulate_and_broadcast     | Cosign::PreflightRejected | "Pre-flight"   | …PreflightRejected   | passes, broadcasts
#   preflight_cosigned_wire!   | Cosign::PreflightRejected | "Pre-flight"   | …PreflightUnavailable| REFUSES (…Unavailable)
#
# The broadcasting caller may pass an empty answer because the node pre-flights
# its own send. The cash-out wire is broadcast by a browser with
# skipPreflight:true, so nothing checks it after the house — it alone fails
# closed.
#
# THE ERROR TYPES ARE THE GEM'S. `Solana::Vault::PreflightRejected` is an ALIAS
# for `Solana::Cosign::PreflightRejected` and `PreflightUnavailable` subclasses
# it, so the operator broadcast path and the cosign path raise ONE hierarchy.
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

  # Stands in for `Cosign::Completer`, which is where the two cosign callers'
  # simulation lives now. It records the call and answers the way the real one
  # does, so the caller's own return value is still under test.
  class CompleterSpy
    attr_reader :calls

    def initialize
      @calls = []
    end

    def complete(signed_wire, expectation:, before_send: nil, **rest)
      @calls << { wire: signed_wire, expectation: expectation, before_send: before_send, rest: rest }
      Solana::Cosign::Completer::Completed.new(
        signature: "SIG_FROM_COMPLETER", wire_base64: signed_wire, confirmation_status: "confirmed"
      )
    end
  end

  EIGHT_LOGS = (1..8).map { |i| "Program log: line #{i}" }.freeze
  PROGRAM_ERR = { "InstructionError" => [1, { "Custom" => 6001 }] }.freeze

  VAULT_SOURCE = File.read(Rails.root.join("app", "services", "solana", "vault.rb")).freeze

  def vault_with(client)
    vault = Solana::Vault.allocate
    vault.instance_variable_set(:@client, client)
    vault
  end

  def expected_failure(prefix)
    "#{prefix} simulation failed: #{PROGRAM_ERR.inspect}\n#{EIGHT_LOGS.last(6).join("\n")}"
  end

  # ── Settings: identical for both ──────────────────────────────────────────

  %i[simulate_and_broadcast preflight_cosigned_wire!].each do |caller|
    test "#{caller} simulates WIRE with sig_verify off, a replaced blockhash, and the client's default commitment" do
      client = StubClient.new({ "err" => nil })
      vault_with(client).public_send(caller, "WIRE")

      assert_equal 1, client.simulate_calls.size
      call = client.simulate_calls.first
      assert_equal "WIRE", call[:wire]
      assert_equal({ sig_verify: false, replace_recent_blockhash: true }, call[:opts],
                   "neither caller passes a commitment, so the gem's own default stays in force")
    end
  end

  # ── A program refusal: class and exact message ────────────────────────────

  {
    simulate_and_broadcast: ["Pre-flight", Solana::Cosign::PreflightRejected],
    preflight_cosigned_wire!: ["Pre-flight", Solana::Cosign::PreflightRejected]
  }.each do |caller, (prefix, klass)|
    test "#{caller} refuses a program error as exactly #{klass.name}, keeping the last six log lines" do
      client = StubClient.new({ "err" => PROGRAM_ERR, "logs" => EIGHT_LOGS })

      error = assert_raises(klass) { vault_with(client).public_send(caller, "WIRE") }

      assert_instance_of klass, error
      assert_equal expected_failure(prefix), error.message
      assert_empty client.sent, "a refused simulation must never reach the chain"
    end
  end

  test "a program error with no logs carries no trailing newline, for every caller" do
    %i[simulate_and_broadcast preflight_cosigned_wire!].each do |caller|
      client = StubClient.new({ "err" => "AccountNotFound" })
      error = assert_raises(Solana::Cosign::PreflightRejected) { vault_with(client).public_send(caller, "WIRE") }
      assert_match(/simulation failed: "AccountNotFound"\z/, error.message, caller.to_s)
    end
  end

  # ── The simulation call itself raising ────────────────────────────────────

  test "simulate_and_broadcast types an unrunnable simulation as exactly PreflightRejected" do
    client = StubClient.new(raises: Solana::Client::RpcError.new("429 Too Many Requests"))

    error = assert_raises(Solana::Vault::PreflightRejected) { vault_with(client).simulate_and_broadcast("WIRE") }

    assert_instance_of Solana::Vault::PreflightRejected, error
    assert_equal "Pre-flight simulation could not be run: 429 Too Many Requests", error.message
  end

  # The one difference between the two surviving rows: the cash-out wire's sole
  # pre-flight distinguishes "the program refused it" from "we never got an
  # answer", because only the first is advice a player can act on.
  test "preflight_cosigned_wire! types an unrunnable simulation as PreflightUnavailable, not a bare rejection" do
    client = StubClient.new(raises: Solana::Client::RpcError.new("429 Too Many Requests"))

    error = assert_raises(Solana::Vault::PreflightUnavailable) { vault_with(client).preflight_cosigned_wire!("WIRE") }

    assert_instance_of Solana::Vault::PreflightUnavailable, error
    assert_equal "Pre-flight simulation could not be run: 429 Too Many Requests", error.message
    assert_kind_of Solana::Cosign::PreflightRejected, error,
                   "still provably un-sent — a rescue of the parent keeps catching it"
  end

  # ── An empty or err-less answer ───────────────────────────────────────────

  [nil, {}, { "logs" => ["Program log: no err key"] }].each do |answer|
    test "simulate_and_broadcast lets a #{answer.inspect} answer through to its own node-preflighted send" do
      client = StubClient.new(answer)

      vault_with(client).simulate_and_broadcast("WIRE")

      assert_equal 1, client.sent.size, "the node pre-flights this send, so the empty answer is not the last check"
    end

    test "preflight_cosigned_wire! REFUSES a #{answer.inspect} answer — nothing pre-flights that wire after us" do
      client = StubClient.new(answer)

      assert_raises(Solana::Vault::PreflightUnavailable) { vault_with(client).preflight_cosigned_wire!("WIRE") }
      assert_empty client.sent
    end
  end

  # ── THE TWO ROWS THAT LEFT ────────────────────────────────────────────────
  #
  # Driven rather than assumed. The client here would REFUSE the simulation, so
  # a caller that still reached #simulate_wire! would raise instead of returning
  # the completer's signature — which is what makes `assert_empty
  # client.simulate_calls` a measurement and not merely an absence.

  %i[cosign_and_broadcast_entry cosign_and_broadcast_create_contest].each do |caller|
    test "#{caller} no longer simulates through #simulate_wire! — the completer does it" do
      client = StubClient.new({ "err" => PROGRAM_ERR, "logs" => EIGHT_LOGS })
      spy = CompleterSpy.new
      vault = vault_with(client)

      signature = vault.stub(:cosign_completer, spy) do
        vault.public_send(caller, "WIRE", expectation: :the_expectation)
      end

      assert_equal "SIG_FROM_COMPLETER", signature, "the caller returns the completer's signature"
      assert_equal 1, spy.calls.size
      assert_equal "WIRE", spy.calls.first[:wire]
      assert_equal :the_expectation, spy.calls.first[:expectation],
                   "the expectation is handed straight through — the completer refuses against it"
      assert_empty client.simulate_calls,
                   "this caller's copy of the simulate-and-read-err block is gone; a refusing " \
                   "simulation here proves nothing re-ran it in the vault"
      assert_empty client.sent, "and the vault sends nothing of its own on this path"
    end

    test "#{caller} forwards before_send to the completer, where the stamp precedes the send" do
      spy = CompleterSpy.new
      vault = vault_with(StubClient.new({ "err" => nil }))
      stamp = ->(_sig) { nil }

      vault.stub(:cosign_completer, spy) do
        vault.public_send(caller, "WIRE", expectation: :the_expectation, before_send: stamp)
      end

      assert_same stamp, spy.calls.first[:before_send]
    end
  end

  # ── THE TABLE IS COMPLETE ─────────────────────────────────────────────────
  #
  # A pinned table of callers is only a pin while it names every caller. Read
  # the set off vault.rb rather than trusting the comment at the top of this
  # file, so a third caller added later fails HERE — with the row it owes —
  # instead of running untested behind an out-of-date list.

  def methods_calling_simulate_wire
    current = nil
    found = []
    VAULT_SOURCE.each_line do |line|
      current = Regexp.last_match(1) if line =~ /^\s*def ([a-z_][\w?!]*)/
      next if line =~ /^\s*def simulate_wire!/

      found << current if line.include?("simulate_wire!(")
    end
    found.uniq
  end

  test "exactly two methods call #simulate_wire!, and both are pinned above" do
    assert_equal %w[simulate_and_broadcast preflight_cosigned_wire!].sort,
                 methods_calling_simulate_wire.sort,
                 "a new caller of the one simulate-and-read-err block needs a row in this file"
  end

  # THE CONTROL for the reader above: it must really find call sites, or the
  # assertion is one that passes on an empty result forever.
  test "CONTROL — the source reader finds a call site that is really there" do
    assert_includes methods_calling_simulate_wire, "simulate_and_broadcast"
    assert_match(/def simulate_wire!\(signed_wire_base64, label:, refusal:/, VAULT_SOURCE,
                 "the helper itself still exists under the name this test reads for")
  end

  # ── WHY DROPPING TWO ROWS IS SAFE ─────────────────────────────────────────
  #
  # The two cosign callers did not stop simulating; the simulation moved into
  # `Cosign::Completer#complete`, with the same two settings. The app's safety
  # argument for the deletion rests on that, so it is asserted against the gem
  # rather than assumed — the same way this suite already pins
  # `Solana::Client`'s retry loop.

  test "CONTROL — Cosign::Completer#complete runs the simulation the vault stopped running" do
    source = File.read(Gem.loaded_specs["solana-studio"].gem_dir + "/lib/solana/cosign/completer.rb")
    complete_body = source[/def complete\(.*?\n      end\n/m]

    refute_nil complete_body, "Completer#complete could not be read — this control is not measuring anything"
    assert_match(/simulate: true/, complete_body, "the simulation is ON by default, and the vault passes no override")
    assert_match(/run_simulation!\(wire_base64, commitment, signature\) if simulate/, complete_body)
    assert_match(/simulate_transaction\(wire_base64, sig_verify: false, replace_recent_blockhash: true/, source,
                 "and it uses the settings this file pins for the two remaining vault callers")
  end
end
