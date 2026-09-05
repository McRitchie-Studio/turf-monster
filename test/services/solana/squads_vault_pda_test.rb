require "test_helper"

# Unit half of admin-shows-devnet-authority. The integration suite
# (test/integration/contract_upgrade_authority_test.rb) proves the admin
# deployment-state card RENDERS the right authority on each cluster; this
# proves the PRIMITIVE that card calls.
#
# THE BUG. `app/views/contract/_section_admin_state.html.erb` hardcoded the
# DEVNET Squads vault PDA into markup, so `turf-monster-mainnet` presented the
# devnet Squad as the live program upgrade authority — under a caption reading
# "Only the Squad can ship upgrades." Every other reader of that value already
# honoured SOLANA_SQUADS_VAULT_PDA; the view could not follow it.
#
# The addresses below are the on-chain truth, re-read 2026-09-05:
#   solana program show EQGFJAc…bpMJ --url devnet       -> BW13kgfi…H6kC
#   solana program show DaFv83yo…zxMM --url mainnet-beta -> Bk9sS7ii…GdJm
# They are PUBLIC PDAs, not secrets.
class Solana::SquadsVaultPdaTest < ActiveSupport::TestCase
  DEVNET  = "BW13kgfiG2koFn3WRkte21NW9TFygsD1ge2fNJdjH6kC".freeze
  MAINNET = "Bk9sS7iiSRL18vuo2KVzkeGw7EekKqxMCjrdoyGGdJm".freeze

  # Deliberately neither cluster's real vault. Its only job is to prove the
  # override is READ rather than assumed — an assertion against MAINNET would
  # also pass if the method simply hardcoded the mainnet literal.
  OVERRIDE = "SoLoVeRRiDeNoTaReAlVaUlTPdA111111111111111".freeze

  def with_vault_env(value)
    previous = ENV["SOLANA_SQUADS_VAULT_PDA"]
    if value.nil?
      ENV.delete("SOLANA_SQUADS_VAULT_PDA")
    else
      ENV["SOLANA_SQUADS_VAULT_PDA"] = value
    end
    yield
  ensure
    previous.nil? ? ENV.delete("SOLANA_SQUADS_VAULT_PDA") : ENV["SOLANA_SQUADS_VAULT_PDA"] = previous
  end

  # --- the two clusters resolve to two DIFFERENT vaults ---
  #
  # This pair is the regression. A single-cluster assertion passes against a
  # hardcoded literal too, which would be the same bug wearing a different
  # constant; only driving BOTH configurations distinguishes them.

  test "devnet resolves to the devnet Squads vault" do
    with_vault_env(nil) do
      assert_equal DEVNET, Solana::Config.squads_vault_pda("devnet")
    end
  end

  test "mainnet-beta resolves to the mainnet Squads vault" do
    with_vault_env(nil) do
      assert_equal MAINNET, Solana::Config.squads_vault_pda("mainnet-beta")
    end
  end

  # Belt to the braces above: if the two literals are ever collapsed into one
  # (a copy-paste that pins both defaults to the same address), each test above
  # still passes for the cluster it names. This one does not.
  test "the two clusters never share a vault" do
    with_vault_env(nil) do
      refute_equal Solana::Config.squads_vault_pda("devnet"),
                   Solana::Config.squads_vault_pda("mainnet-beta"),
                   "devnet and mainnet are separate Squads — a shared address means " \
                   "one of the two cluster defaults is wrong"
    end
  end

  # --- the env override, which is what the deployed apps actually use ---

  test "SOLANA_SQUADS_VAULT_PDA wins on BOTH clusters" do
    with_vault_env(OVERRIDE) do
      assert_equal OVERRIDE, Solana::Config.squads_vault_pda("devnet")
      assert_equal OVERRIDE, Solana::Config.squads_vault_pda("mainnet-beta")
    end
  end

  # `heroku config:set SOLANA_SQUADS_VAULT_PDA=` sets an EMPTY string, not an
  # unset var. Rendering "" as the upgrade authority is worse than rendering the
  # cluster default, so blank falls through.
  test "a blank override falls through to the cluster default" do
    with_vault_env("") do
      assert_equal DEVNET,  Solana::Config.squads_vault_pda("devnet")
      assert_equal MAINNET, Solana::Config.squads_vault_pda("mainnet-beta")
    end
  end

  # An unrecognised cluster (localnet, or a typo in SOLANA_NETWORK) must not
  # claim MAINNET authority. Devnet is the safe landing — the same fail-safe
  # direction USDC_MINT / IDL_PATH take for the same reason.
  test "an unknown cluster falls back to devnet, never to mainnet" do
    with_vault_env(nil) do
      %w[localnet testnet mainnet MAINNET-BETA].each do |network|
        assert_equal DEVNET, Solana::Config.squads_vault_pda(network),
                     "#{network.inspect} must not resolve to the mainnet Squad"
      end
    end
  end

  # The default argument is what app code relies on: no call site passes a
  # network, so the zero-arg form has to read the live NETWORK constant.
  test "the zero-argument form follows Solana::Config::NETWORK" do
    with_vault_env(nil) do
      assert_equal Solana::Config.squads_vault_pda(Solana::Config::NETWORK),
                   Solana::Config.squads_vault_pda
    end
  end
end
