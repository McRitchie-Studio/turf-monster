require "test_helper"

# admin-shows-devnet-authority — the admin deployment-state card must present
# the upgrade authority OF THE CLUSTER IT IS RUNNING ON.
#
# THE BUG. `app/views/contract/_section_admin_state.html.erb` carried the
# DEVNET Squads vault PDA as a literal in markup, under a caption reading
# "Squads V4 2-of-3 vault PDA. Only the Squad can ship upgrades." On
# `turf-monster-mainnet` that is a WRONG ADDRESS STATED AUTHORITATIVELY, on the
# one page an operator consults before proposing a program upgrade — and it was
# the only copy of this defect a human ever saw in a browser. Every other reader
# (Admin::VaultInitController, `solana:init_vault`) already honoured
# SOLANA_SQUADS_VAULT_PDA; the view could not follow it.
#
# WHY THIS TEST DRIVES BOTH CLUSTERS. A suite that only asserts the mainnet
# address passes against a view that hardcodes the mainnet address — the same
# bug with a different constant. So every case here renders the real page twice,
# once per cluster configuration, and asserts the OTHER cluster's address is
# absent. Both halves are required: absence alone would also pass if the admin
# card stopped rendering, so the authority cell is extracted by position and
# compared for EQUALITY rather than searched for in the body.
#
# The addresses are the on-chain truth, re-read 2026-09-05:
#   solana program show EQGFJAc…bpMJ --url devnet       -> BW13kgfi…H6kC
#   solana program show DaFv83yo…zxMM --url mainnet-beta -> Bk9sS7ii…GdJm
# Public PDAs, not secrets.
class ContractUpgradeAuthorityTest < ActionDispatch::IntegrationTest
  DEVNET  = Solana::Config::DEVNET_SQUADS_VAULT_PDA
  MAINNET = Solana::Config::MAINNET_SQUADS_VAULT_PDA

  # The <dd> that belongs to the "Upgrade authority" <dt>. Extracting BY
  # POSITION rather than grepping the whole body is what makes the negative
  # assertions mean something: a card that failed to render returns nil here
  # instead of silently satisfying "the wrong address is absent".
  def upgrade_authority_cell(body)
    body[%r{Upgrade authority</dt>\s*<dd[^>]*>\s*(.*?)\s*</dd>}m, 1]&.strip
  end

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

  # NETWORK is a LOAD-TIME constant (deliberately — see the OPSEC-012 comment in
  # config.rb), so swapping the constant is the only way to put this process on
  # the other cluster. Same technique the RPC-credential suite uses for RPC_URL;
  # Rails parallelises by FORK, so it never crosses workers.
  def with_network(network)
    previous = Solana::Config::NETWORK
    Solana::Config.send(:remove_const, :NETWORK)
    Solana::Config.const_set(:NETWORK, network)
    yield
  ensure
    Solana::Config.send(:remove_const, :NETWORK)
    Solana::Config.const_set(:NETWORK, previous)
  end

  # One assertion, both directions, so a failure names the cluster.
  def assert_renders_authority(expected, absent, cluster)
    get contract_path
    assert_response :success

    cell = upgrade_authority_cell(response.body)
    assert cell.present?,
      "#{cluster}: the admin deployment-state card rendered no Upgrade authority cell — " \
      "the negative assertion below would pass vacuously"
    assert_equal expected, cell,
      "#{cluster}: the admin card presents the wrong Squads vault as the upgrade authority"
    assert_no_match(/#{Regexp.escape(absent)}/, response.body,
      "#{cluster}: the OTHER cluster's Squads vault PDA appears on the page")
  end

  setup { log_in_as(users(:alex)) }

  # --- cluster configuration 1: the env override the deployed apps set ---
  #
  # This is the production shape. `turf-monster-mainnet` sets
  # SOLANA_SQUADS_VAULT_PDA correctly and every other site resolved to it; only
  # this page ignored it.

  test "with the mainnet vault configured, the admin card shows the MAINNET authority" do
    with_vault_env(MAINNET) { assert_renders_authority(MAINNET, DEVNET, "SOLANA_SQUADS_VAULT_PDA=mainnet") }
  end

  test "with the devnet vault configured, the admin card shows the DEVNET authority" do
    with_vault_env(DEVNET) { assert_renders_authority(DEVNET, MAINNET, "SOLANA_SQUADS_VAULT_PDA=devnet") }
  end

  # --- cluster configuration 2: the network-keyed default, env unset ---
  #
  # Omission must not print a devnet authority on a mainnet build. This is the
  # half that would still be broken if the fix only read the env var.

  test "a mainnet build with no override still shows the MAINNET authority" do
    with_vault_env(nil) do
      with_network("mainnet-beta") { assert_renders_authority(MAINNET, DEVNET, "SOLANA_NETWORK=mainnet-beta") }
    end
  end

  test "a devnet build with no override still shows the DEVNET authority" do
    with_vault_env(nil) do
      with_network("devnet") { assert_renders_authority(DEVNET, MAINNET, "SOLANA_NETWORK=devnet") }
    end
  end

  # The address alone is a string an operator has to recognise. Naming the
  # cluster beside it is what makes a wrong-cluster reading obvious to a human,
  # which is the failure this task exists to prevent.
  test "the caption names the cluster the authority belongs to" do
    with_vault_env(nil) do
      with_network("mainnet-beta") do
        get contract_path
        assert_response :success
        assert_match(/Squads V4 2-of-3 vault PDA on mainnet-beta/, response.body,
          "the upgrade-authority caption must name the cluster, not describe a generic Squad")
      end
    end
  end

  # --- the standing guard, for surfaces this sweep does not visit ---
  #
  # Holds for views that do not exist yet: no ERB template may name either
  # cluster's Squads vault PDA as a literal. That is the exact mutation this
  # task reverses, kept permanently armed. Modelled on the "no view names
  # Config::RPC_URL" guard in test/integration/rpc_credential_not_in_browser_test.rb.
  test "no view hardcodes a Squads vault PDA" do
    root = Rails.root
    offenders = Dir[root.join("app/views/**/*.erb")].select do |path|
      contents = File.read(path)
      contents.include?(DEVNET) || contents.include?(MAINNET)
    end

    assert_empty offenders.map { |path| Pathname.new(path).relative_path_from(root).to_s },
      "these views hardcode a cluster-specific Squads vault PDA — the upgrade authority " \
      "differs per cluster, so a literal is wrong on one of them. Use " \
      "Solana::Config.squads_vault_pda."
  end

  # The card is admin-only, so a non-admin must not be reading ANY upgrade
  # authority off this page. Also pins that the extractor above is finding an
  # admin-gated cell rather than something rendered for everyone.
  test "a non-admin sees no upgrade authority at all" do
    log_in_as(users(:jordan))
    get contract_path
    assert_response :success
    assert_nil upgrade_authority_cell(response.body),
      "the deployment-state card is admin-only"
  end
end
