require "test_helper"
require "rake"

# vault-pda-readers-diverge — READER 2 of 2.
#
# THE BUG. `solana:init_vault` resolved the treasury authority as:
#
#   treasury = ENV["TREASURY"].presence || ENV["SOLANA_SQUADS_VAULT_PDA"].presence ||
#              "BW13kgfiG2koFn3WRkte21NW9TFygsD1ge2fNJdjH6kC"   # the DEVNET Squad
#
# The `.presence` chain handled empty values correctly — this reader's defect
# was the OTHER one: the final fallback is the devnet literal on EVERY cluster.
# Run against a mainnet build with SOLANA_SQUADS_VAULT_PDA UNSET — which is the
# live state of turf-monster-mainnet, where the key is ABSENT from the config
# (re-verified 2026-09-05 by key presence: `heroku config --json -a <app>` does
# not carry it, and the table view names it zero times) — the task would pin
# VaultState.treasury_authority to the DEVNET Squad. That value is fixed at
# initialize time and sweep_operator_revenue refuses to pay anywhere else, so
# it is the one field here that a later deploy cannot correct.
#
# ABSENT, not empty. `heroku config:get` prints a bare newline for both states
# and cannot distinguish them; the key-presence read above is the one that can.
#
# WHY THIS DRIVES THE REAL TASK. The resolution is one line inside a rake body;
# asserting it by re-deriving the same expression in the test would certify the
# test, not the task. So the task is INVOKED, with Solana::Vault stubbed by a
# recorder that captures the `treasury_authority:` it is actually handed —
# the same technique test/tasks/solana_preflight_redaction_test.rb uses.
#
# WHY BOTH CLUSTERS, EVERY TIME. Asserting only the mainnet address passes
# against a task that hardcodes the mainnet address — the same bug wearing a
# nicer constant.
#
# On-chain truth, re-read 2026-09-05:
#   solana program show EQGFJAc…bpMJ --url devnet       -> BW13kgfi…H6kC
#   solana program show DaFv83yo…zxMM --url mainnet-beta -> Bk9sS7ii…GdJm
class SolanaInitVaultTreasuryTest < ActiveSupport::TestCase
  DEVNET  = Solana::Config::DEVNET_SQUADS_VAULT_PDA
  MAINNET = Solana::Config::MAINNET_SQUADS_VAULT_PDA

  # Neither cluster's real vault, so an assertion against it cannot be
  # satisfied by a hardcoded literal of either kind.
  OVERRIDE = "SoLoVeRRiDeNoTaReAlVaUlTPdA111111111111111".freeze

  # Records what `initialize_vault` was called with. Every other method exists
  # only to let the task reach that call without touching the network.
  class RecordingVault
    attr_reader :init_calls

    def initialize = @init_calls = []
    def client = FakeClient.new
    def vault_state_pda = [("\x01" * 32).b, 255]
    def op_rev_ata_pda(_mint) = [("\x02" * 32).b, 254]

    def initialize_vault(signers:, threshold:, treasury_authority:)
      @init_calls << { signers: signers, threshold: threshold, treasury_authority: treasury_authority }
      { signature: "FAKE_SIG", vault_pda: "FAKE_VAULT_PDA" }
    end

    class FakeClient
      def get_balance(_address) = { "value" => 0 }
    end
  end

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("solana:init_vault")
    @task = Rake::Task["solana:init_vault"]
  end

  # Three signers, as the task requires. Real base58 pubkeys from the
  # documented signer set; the rake only checks the count, but keeping them
  # real means a future validation there does not silently start failing here.
  SIGNERS = Solana::Config::MULTISIG_SIGNERS

  def run_init_vault(network:, vault_pda_env:, treasury_env: nil)
    recorder = RecordingVault.new
    with_env("SOLANA_SQUADS_VAULT_PDA" => vault_pda_env,
             "TREASURY"                => treasury_env,
             "INIT"                    => "true",
             "SIGNERS"                 => SIGNERS.join(","),
             "THRESHOLD"               => "2") do
      with_network(network) do
        Solana::Vault.stub(:new, recorder) do
          capture_io do
            @task.reenable
            @task.invoke
          end
        end
      end
    end

    assert_equal 1, recorder.init_calls.length,
      "solana:init_vault did not reach initialize_vault — the assertion below would be vacuous"
    recorder.init_calls.first[:treasury_authority]
  end

  # nil VALUE means "delete this key" — the distinction between an absent and
  # an empty variable is load-bearing here, so it has to be expressible.
  def with_env(pairs)
    previous = pairs.keys.index_with { |key| ENV[key] }
    pairs.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    previous.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  # NETWORK is a load-time constant; swapping it is the only way to put this
  # process on the other cluster. Rails parallelises by FORK, so it never
  # crosses workers.
  def with_network(network)
    previous = Solana::Config::NETWORK
    Solana::Config.send(:remove_const, :NETWORK)
    Solana::Config.const_set(:NETWORK, network)
    yield
  ensure
    Solana::Config.send(:remove_const, :NETWORK)
    Solana::Config.const_set(:NETWORK, previous)
  end

  # --- the network-keyed default: what a production run of this task takes ---

  test "on devnet with no override it pins the DEVNET Squad" do
    assert_equal DEVNET, run_init_vault(network: "devnet", vault_pda_env: nil)
  end

  test "on mainnet-beta with no override it pins the MAINNET Squad" do
    assert_equal MAINNET, run_init_vault(network: "mainnet-beta", vault_pda_env: nil)
  end

  # Belt to the braces above: collapse the two cluster defaults into one
  # address and each test above still passes for the cluster it names.
  test "the task never pins the same vault on both clusters" do
    devnet  = run_init_vault(network: "devnet",       vault_pda_env: nil)
    mainnet = run_init_vault(network: "mainnet-beta", vault_pda_env: nil)
    refute_equal devnet, mainnet,
      "devnet and mainnet-beta run separate Squads — pinning one address on both is wrong on one of them"
  end

  # --- unset vs EMPTY vs whitespace ---
  #
  # UNSET is the live state of both deployed apps — the key is ABSENT from both
  # configs — so it is the case a production run actually exercises, and the
  # network-keyed-default pair above is what covers it. EMPTY and
  # WHITESPACE-ONLY are defensive coverage for states no deployed app is in.
  # Each gets its own test.

  test "an EMPTY SOLANA_SQUADS_VAULT_PDA still pins the right Squad per cluster" do
    assert_equal DEVNET,  run_init_vault(network: "devnet",       vault_pda_env: "")
    assert_equal MAINNET, run_init_vault(network: "mainnet-beta", vault_pda_env: "")
  end

  test "a WHITESPACE-ONLY SOLANA_SQUADS_VAULT_PDA still pins the right Squad per cluster" do
    assert_equal DEVNET,  run_init_vault(network: "devnet",       vault_pda_env: "   ")
    assert_equal MAINNET, run_init_vault(network: "mainnet-beta", vault_pda_env: "   ")
  end

  test "no empty-ish value ever pins a blank treasury authority" do
    [nil, "", "   ", "\t\n"].each do |value|
      %w[devnet mainnet-beta].each do |network|
        pinned = run_init_vault(network: network, vault_pda_env: value)
        assert pinned.present?,
          "#{value.inspect} on #{network} would pin a BLANK treasury authority into VaultState"
      end
    end
  end

  # --- the two overrides, in precedence order ---

  test "SOLANA_SQUADS_VAULT_PDA overrides the cluster default on BOTH clusters" do
    assert_equal OVERRIDE, run_init_vault(network: "devnet",       vault_pda_env: OVERRIDE)
    assert_equal OVERRIDE, run_init_vault(network: "mainnet-beta", vault_pda_env: OVERRIDE)
  end

  # TREASURY= is the task-level, one-invocation override and outranks both the
  # environment variable and the cluster default.
  test "TREASURY outranks SOLANA_SQUADS_VAULT_PDA and the cluster default" do
    assert_equal OVERRIDE,
                 run_init_vault(network: "mainnet-beta", vault_pda_env: DEVNET, treasury_env: OVERRIDE)
    assert_equal OVERRIDE,
                 run_init_vault(network: "devnet", vault_pda_env: MAINNET, treasury_env: OVERRIDE)
  end

  # The address is echoed to the operator before the TX goes out — it is the
  # last chance to notice a wrong-cluster value, so it has to be printed.
  test "the task prints the treasury authority it is about to pin" do
    recorder = RecordingVault.new
    output = nil
    with_env("SOLANA_SQUADS_VAULT_PDA" => nil, "TREASURY" => nil, "INIT" => "true",
             "SIGNERS" => SIGNERS.join(","), "THRESHOLD" => "2") do
      with_network("mainnet-beta") do
        Solana::Vault.stub(:new, recorder) do
          output, = capture_io do
            @task.reenable
            @task.invoke
          end
        end
      end
    end

    assert_match(/Treasury authority:\s+#{Regexp.escape(MAINNET)}/, output,
      "the operator must see which Squads vault is about to be pinned into VaultState")
    refute_includes output, DEVNET,
      "a mainnet run printed the DEVNET Squads vault"
  end
end
