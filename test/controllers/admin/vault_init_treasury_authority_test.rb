require "test_helper"

# vault-pda-readers-diverge — READER 1 of 2.
#
# THE BUG. `Admin::VaultInitController` offered a default treasury authority
# read as:
#
#   DEFAULT_TREASURY_AUTHORITY = ENV.fetch(
#     "SOLANA_SQUADS_VAULT_PDA",
#     "BW13kgfiG2koFn3WRkte21NW9TFygsD1ge2fNJdjH6kC"   # the DEVNET Squad
#   )
#
# Two defects in one expression — one LIVE, one LATENT:
#
#   1. NOT NETWORK-KEYED, and this is the one production ran. The fallback was
#      the devnet literal on every cluster, and the key SOLANA_SQUADS_VAULT_PDA
#      is ABSENT on turf-monster-mainnet and turf-monster-qa alike (re-verified
#      2026-09-05 by key presence: `heroku config --json -a <app>` does not
#      carry the key, and the table view — which names every key regardless of
#      value — names it zero times). So `ENV.fetch` DID take its default, and
#      the mainnet vault-init form pre-filled the DEVNET Squad BW13…H6kC — the
#      address VaultState.treasury_authority is PINNED to at initialize time,
#      and which sweep_operator_revenue then refuses to pay anywhere else.
#   2. `ENV.fetch` TAKES ITS DEFAULT ONLY FOR AN ABSENT KEY. A key present but
#      empty yields "", never reaching the fallback. LATENT, never live: no
#      deployed app sets this key, so no form ever rendered a blank treasury.
#      One `heroku config:set SOLANA_SQUADS_VAULT_PDA=` would have made it
#      live, which is why the replacement resolves via `.presence`.
#
# Do NOT verify the key's state with `heroku config:get` — it prints a bare
# newline for an absent key AND for a present-but-empty one, so it cannot tell
# them apart. Reading it as "empty" is how this header first carried a false
# production fact.
#
# Bounded rather than an incident: the mainnet VaultState PDA
# GBu44HFJjq61WnS9UV1twcSrCC6SkuXHK8RM6tUKsWzV already exists, so `build`
# raises "Vault already initialized" before any of this is submitted, and the
# on-chain treasury authority is correctly Bk9sS7ii…GdJm. This is a WRONG
# address offered to an operator, not money moved.
#
# WHY BOTH CLUSTERS, EVERY TIME. A suite asserting only the mainnet address
# passes against a reader that hardcodes the mainnet address — the same bug
# wearing a nicer constant. Every case below drives BOTH configurations.
#
# On-chain truth, re-read 2026-09-05:
#   solana program show EQGFJAc…bpMJ --url devnet       -> BW13kgfi…H6kC
#   solana program show DaFv83yo…zxMM --url mainnet-beta -> Bk9sS7ii…GdJm
# Public PDAs, not secrets.
class Admin::VaultInitTreasuryAuthorityTest < ActionDispatch::IntegrationTest
  DEVNET  = Solana::Config::DEVNET_SQUADS_VAULT_PDA
  MAINNET = Solana::Config::MAINNET_SQUADS_VAULT_PDA

  # Deliberately neither cluster's real vault, so an assertion against it
  # cannot be satisfied by a hardcoded literal of either kind.
  OVERRIDE = "SoLoVeRRiDeNoTaReAlVaUlTPdA111111111111111".freeze

  # `show` reads VaultState over RPC. nil = uninitialized, which is the branch
  # that renders the init form (and therefore the treasury input under test).
  class UninitializedVault
    def read_vault_state(**_opts) = nil
  end

  def with_vault_env(value)
    previous = ENV["SOLANA_SQUADS_VAULT_PDA"]
    value.nil? ? ENV.delete("SOLANA_SQUADS_VAULT_PDA") : ENV["SOLANA_SQUADS_VAULT_PDA"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("SOLANA_SQUADS_VAULT_PDA") : ENV["SOLANA_SQUADS_VAULT_PDA"] = previous
  end

  # NETWORK is a LOAD-TIME constant (deliberately — see the OPSEC-012 note in
  # config.rb), so swapping the constant is the only way to put this process on
  # the other cluster. Same technique the sibling suite uses; Rails parallelises
  # by FORK, so it never crosses workers.
  def with_network(network)
    previous = Solana::Config::NETWORK
    Solana::Config.send(:remove_const, :NETWORK)
    Solana::Config.const_set(:NETWORK, network)
    yield
  ensure
    Solana::Config.send(:remove_const, :NETWORK)
    Solana::Config.const_set(:NETWORK, previous)
  end

  # The value attribute of the treasury_authority input — extracted BY NAME
  # rather than grepped out of the whole body, so a form that stopped rendering
  # returns nil here instead of silently satisfying "the wrong address is
  # absent".
  def rendered_treasury_default
    response.body[/name="treasury_authority"[^>]*\svalue="([^"]*)"/, 1]
  end

  def get_vault_init
    Solana::Vault.stub(:new, UninitializedVault.new) { get admin_vault_init_path }
  end

  # One assertion, both directions, so a failure names the cluster.
  def assert_offers_treasury(expected, absent, cluster)
    get_vault_init
    assert_response :success

    value = rendered_treasury_default
    assert_not_nil value,
      "#{cluster}: the vault-init form rendered no treasury_authority input — " \
      "the assertions below would pass vacuously"
    assert_equal expected, value,
      "#{cluster}: the vault-init form offers the wrong Squads vault as treasury_authority"
    assert_no_match(/#{Regexp.escape(absent)}/, response.body,
      "#{cluster}: the OTHER cluster's Squads vault PDA appears on the page")
  end

  setup { log_in_as(users(:alex)) }

  # --- the reader itself, both clusters ---
  #
  # `default_treasury_authority` is a METHOD, not a constant, precisely so this
  # pair can exist: a load-time constant freezes to whichever cluster the test
  # process booted on and cannot be driven across both.

  test "the controller's default resolves to the DEVNET Squad on devnet" do
    with_vault_env(nil) do
      with_network("devnet") do
        assert_equal DEVNET, Admin::VaultInitController.default_treasury_authority
      end
    end
  end

  test "the controller's default resolves to the MAINNET Squad on mainnet-beta" do
    with_vault_env(nil) do
      with_network("mainnet-beta") do
        assert_equal MAINNET, Admin::VaultInitController.default_treasury_authority
      end
    end
  end

  # Belt to the braces above. If the two cluster defaults were ever collapsed
  # into one address, each test above still passes for the cluster it names.
  # This one does not.
  test "the controller never offers the same vault on both clusters" do
    with_vault_env(nil) do
      devnet  = with_network("devnet")       { Admin::VaultInitController.default_treasury_authority }
      mainnet = with_network("mainnet-beta") { Admin::VaultInitController.default_treasury_authority }
      refute_equal devnet, mainnet,
        "devnet and mainnet-beta run separate Squads — one shared address means one is wrong"
    end
  end

  # --- what the operator actually sees, both clusters ---
  #
  # The reader above is only half the claim: the form has to CARRY it. A page
  # that dropped the input, or pre-filled it from somewhere else, passes every
  # test above.

  test "a devnet build pre-fills the form with the DEVNET Squad" do
    with_vault_env(nil) { with_network("devnet") { assert_offers_treasury(DEVNET, MAINNET, "SOLANA_NETWORK=devnet") } }
  end

  test "a mainnet build pre-fills the form with the MAINNET Squad" do
    with_vault_env(nil) do
      with_network("mainnet-beta") { assert_offers_treasury(MAINNET, DEVNET, "SOLANA_NETWORK=mainnet-beta") }
    end
  end

  # --- unset vs EMPTY vs whitespace: three states, not one ---
  #
  # UNSET is the one both production apps are actually in — the key is ABSENT
  # from both configs. EMPTY is the distinction the old `ENV.fetch` reader got
  # wrong, and it is defensive coverage rather than a production state: no
  # deployed app has ever set this key. Each state gets its own test so none of
  # them can pass on the strength of another.

  # THE LIVE PRODUCTION STATE. The key SOLANA_SQUADS_VAULT_PDA is ABSENT from
  # turf-monster-mainnet and turf-monster-qa (re-verified 2026-09-05 by key
  # presence). Under `ENV.fetch` this took the default — which was the devnet
  # literal on every cluster, so the mainnet form offered the DEVNET Squad.
  test "an UNSET variable falls through to the cluster default" do
    with_vault_env(nil) do
      with_network("devnet")       { assert_equal DEVNET,  Admin::VaultInitController.default_treasury_authority }
      with_network("mainnet-beta") { assert_equal MAINNET, Admin::VaultInitController.default_treasury_authority }
    end
  end

  # NOT a production state — no deployed app sets this key. Defensive coverage
  # for what `heroku config:set SOLANA_SQUADS_VAULT_PDA=` would create, which
  # `ENV.fetch` would have resolved to "".
  test "an EMPTY variable falls through to the cluster default" do
    with_vault_env("") do
      with_network("devnet")       { assert_equal DEVNET,  Admin::VaultInitController.default_treasury_authority }
      with_network("mainnet-beta") { assert_equal MAINNET, Admin::VaultInitController.default_treasury_authority }
    end
  end

  test "a WHITESPACE-ONLY variable falls through to the cluster default" do
    with_vault_env("   ") do
      with_network("devnet")       { assert_equal DEVNET,  Admin::VaultInitController.default_treasury_authority }
      with_network("mainnet-beta") { assert_equal MAINNET, Admin::VaultInitController.default_treasury_authority }
    end
  end

  # The rendered half of the same claim: an empty variable must not reach the
  # browser as a blank input on either cluster. Latent rather than live — no
  # deployed app sets this key — but a blank pre-fill on a field pinned at
  # `initialize` is worth pinning against.
  test "an EMPTY variable never renders a blank treasury input" do
    with_vault_env("") do
      with_network("devnet")       { assert_offers_treasury(DEVNET, MAINNET, "empty on devnet") }
      with_network("mainnet-beta") { assert_offers_treasury(MAINNET, DEVNET, "empty on mainnet-beta") }
    end
  end

  test "no empty-ish value ever resolves to a blank address" do
    [nil, "", "   ", "\t\n"].each do |value|
      with_vault_env(value) do
        %w[devnet mainnet-beta].each do |network|
          with_network(network) do
            assert Admin::VaultInitController.default_treasury_authority.present?,
              "#{value.inspect} on #{network} left the vault-init default blank"
          end
        end
      end
    end
  end

  # --- the override still wins, on both clusters ---
  #
  # The runbook escape hatch for pointing an app at a fresh Squad. Asserting a
  # value that is NEITHER cluster's real vault is what proves the variable is
  # READ rather than coincidentally matched.

  test "SOLANA_SQUADS_VAULT_PDA overrides the default on BOTH clusters" do
    with_vault_env(OVERRIDE) do
      with_network("devnet")       { assert_equal OVERRIDE, Admin::VaultInitController.default_treasury_authority }
      with_network("mainnet-beta") { assert_equal OVERRIDE, Admin::VaultInitController.default_treasury_authority }
    end
  end

  # --- `build` uses the same reader as `show` ---
  #
  # `show` pre-fills the form and `build` supplies the fallback when the field
  # comes back empty. If those two ever resolved differently, an operator could
  # be shown one authority and pin another. Rather than assert the coupling in
  # prose, drive `build` with no treasury param and read what it echoes back.

  def build_with_no_treasury
    signers = Solana::Config::MULTISIG_SIGNERS
    Solana::Vault.stub(:new, BuildingVault.new) do
      post admin_build_vault_init_path,
           params: { creator_pubkey: Solana::Config::INIT_AUTHORITY,
                     signer_1: signers[0], signer_2: signers[1], signer_3: signers[2],
                     threshold: 2 },
           as: :json
    end
    JSON.parse(response.body)
  end

  # Uninitialized (so `build` proceeds) and echoes the treasury it was handed.
  class BuildingVault
    def read_vault_state(**_opts) = nil

    def build_initialize_vault(creator_pubkey:, signers:, threshold:, treasury_authority:)
      { serialized_tx: "FAKE_TX", signers: signers, threshold: threshold,
        treasury_authority: treasury_authority, creator: creator_pubkey }
    end
  end

  test "build falls back to the DEVNET Squad on devnet when the field is empty" do
    with_vault_env(nil) do
      with_network("devnet") do
        assert_equal DEVNET, build_with_no_treasury["treasury_authority"]
      end
    end
  end

  test "build falls back to the MAINNET Squad on mainnet-beta when the field is empty" do
    with_vault_env(nil) do
      with_network("mainnet-beta") do
        # validate_init_params! requires creator == INIT_AUTHORITY on mainnet,
        # which the helper already supplies.
        assert_equal MAINNET, build_with_no_treasury["treasury_authority"]
      end
    end
  end
end
