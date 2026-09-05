require "test_helper"

# Unit half of admin-shows-devnet-authority. The integration suite
# (test/integration/contract_upgrade_authority_test.rb) proves the admin
# deployment-state card RENDERS the right authority on each cluster; this
# proves the PRIMITIVE that card calls.
#
# THE BUG. `app/views/contract/_section_admin_state.html.erb` hardcoded the
# DEVNET Squads vault PDA into markup, so `turf-monster-mainnet` presented the
# devnet Squad as the live program upgrade authority — under a caption reading
# "Only the Squad can ship upgrades."
#
# CORRECTION (vault-pda-readers-diverge). This header used to add "every other
# reader of that value already honoured SOLANA_SQUADS_VAULT_PDA; the view could
# not follow it." That was false. Admin::VaultInitController and
# `solana:init_vault` both fell back to the DEVNET literal on EVERY cluster,
# and the controller read the variable with `ENV.fetch`, which takes its
# default only when the key is absent — not when it is empty. Both now route
# through Solana::Config.squads_vault_pda; the view was simply the only copy a
# human could see.
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

  # --- the network-keyed default: THE PRODUCTION SHAPE, on both clusters ---
  #
  # This pair is the regression. A single-cluster assertion passes against a
  # hardcoded literal too, which would be the same bug wearing a different
  # constant; only driving BOTH configurations distinguishes them.
  #
  # And this is the path both deployed apps take. SOLANA_SQUADS_VAULT_PDA is
  # empty on turf-monster-mainnet and turf-monster-qa alike (verified
  # 2026-09-05), so every reader on production resolves through the default
  # below, not through the override section further down.

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

  # --- the env override, which NO deployed app currently uses ---
  #
  # Corrected 2026-09-05 (vault-pda-readers-diverge): this section used to be
  # labelled "what the deployed apps actually use", which is backwards.
  # `heroku config:get SOLANA_SQUADS_VAULT_PDA` returns a length-0 string on
  # turf-monster-mainnet AND turf-monster-qa, so the network-keyed DEFAULT
  # above is the production path on both clusters and the override below is a
  # runbook escape hatch for pointing an app at a fresh Squad.

  test "SOLANA_SQUADS_VAULT_PDA wins on BOTH clusters" do
    with_vault_env(OVERRIDE) do
      assert_equal OVERRIDE, Solana::Config.squads_vault_pda("devnet")
      assert_equal OVERRIDE, Solana::Config.squads_vault_pda("mainnet-beta")
    end
  end

  # --- three ways to say "no value", kept apart on purpose ---
  #
  # UNSET, EMPTY and WHITESPACE-ONLY are three distinct states, and Ruby treats
  # them differently: `ENV.fetch(k, default)` takes its default for UNSET only,
  # while `ENV[k].presence` collapses all three. `heroku config:set VAR=` sets
  # the EMPTY one, and that is the live state of both deployed apps — so the
  # case that actually runs on production is the one an `ENV.fetch` reader
  # would get wrong. Asserting them together in a single test would let two
  # pass on the strength of the third, so they get one test each.

  test "an UNSET variable falls through to the cluster default" do
    with_vault_env(nil) do
      assert_equal DEVNET,  Solana::Config.squads_vault_pda("devnet")
      assert_equal MAINNET, Solana::Config.squads_vault_pda("mainnet-beta")
    end
  end

  # The live production state on turf-monster-mainnet and turf-monster-qa.
  test "an EMPTY variable falls through to the cluster default" do
    with_vault_env("") do
      assert_equal DEVNET,  Solana::Config.squads_vault_pda("devnet")
      assert_equal MAINNET, Solana::Config.squads_vault_pda("mainnet-beta")
    end
  end

  # A pasted-with-a-trailing-space config set. Rendering "   " as the upgrade
  # authority is worse than rendering the cluster default.
  test "a WHITESPACE-ONLY variable falls through to the cluster default" do
    with_vault_env("   ") do
      assert_equal DEVNET,  Solana::Config.squads_vault_pda("devnet")
      assert_equal MAINNET, Solana::Config.squads_vault_pda("mainnet-beta")
    end
  end

  # None of the three may yield a blank, on either cluster — the failure the
  # `ENV.fetch` reader in Admin::VaultInitController actually produced.
  test "no empty-ish value ever resolves to a blank address" do
    [nil, "", "   ", "\t\n"].each do |value|
      with_vault_env(value) do
        %w[devnet mainnet-beta].each do |network|
          resolved = Solana::Config.squads_vault_pda(network)
          assert resolved.present?,
                 "#{value.inspect} on #{network} resolved to a blank Squads vault address"
        end
      end
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
