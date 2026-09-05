require "test_helper"

# admin-shows-devnet-authority — the admin deployment-state card must present
# the upgrade authority OF THE CLUSTER IT IS RUNNING ON.
#
# THE BUG. `app/views/contract/_section_admin_state.html.erb` carried the
# DEVNET Squads vault PDA as a literal in markup, under a caption reading
# "Squads V4 2-of-3 vault PDA. Only the Squad can ship upgrades." On
# `turf-monster-mainnet` that is a WRONG ADDRESS STATED AUTHORITATIVELY, on the
# one page an operator consults before proposing a program upgrade — and it was
# the only copy of this defect a human ever saw in a browser.
#
# CORRECTION (vault-pda-readers-diverge). This header used to claim the view
# was the only BROKEN reader — "every other reader (Admin::VaultInitController,
# `solana:init_vault`) already honoured SOLANA_SQUADS_VAULT_PDA". It was not.
# Both of those fell back to the DEVNET literal on EVERY cluster, and because
# the key is ABSENT on both deployed apps (re-verified 2026-09-05 by key
# presence), that fallback is what ran: all three readers had the SAME live
# symptom, the devnet Squad on the mainnet app. The controller carried a second
# defect in the same expression — `ENV.fetch` takes its default only for an
# ABSENT key, never for an empty one — but that one was LATENT, one
# `heroku config:set VAR=` from live, and no deployed app has ever set the key.
# Both now route through Solana::Config.squads_vault_pda, and the guard at the
# bottom of this file was widened from ERB to Ruby and rake so the claim is now
# ENFORCED rather than asserted in prose.
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

  # --- cluster configuration 1: the env override, which NO deployed app sets ---
  #
  # Corrected 2026-09-05 (vault-pda-readers-diverge). This block used to call
  # itself "the production shape" and say `turf-monster-mainnet` "sets
  # SOLANA_SQUADS_VAULT_PDA correctly". Both statements are inverted: the key
  # is ABSENT from turf-monster-mainnet AND turf-monster-qa — not
  # set-and-empty — verified by key presence (`heroku config --json -a <app>`
  # does not carry it; the table view, which names every key regardless of
  # value, names it zero times). `heroku config:get` cannot establish this: it
  # prints a bare newline for absent and for present-but-empty alike. The
  # override is the runbook escape hatch for pointing an app at a fresh Squad;
  # configuration 2 below is what production actually runs.

  test "with the mainnet vault configured, the admin card shows the MAINNET authority" do
    with_vault_env(MAINNET) { assert_renders_authority(MAINNET, DEVNET, "SOLANA_SQUADS_VAULT_PDA=mainnet") }
  end

  test "with the devnet vault configured, the admin card shows the DEVNET authority" do
    with_vault_env(DEVNET) { assert_renders_authority(DEVNET, MAINNET, "SOLANA_SQUADS_VAULT_PDA=devnet") }
  end

  # --- cluster configuration 2: the network-keyed default — THE PRODUCTION SHAPE ---
  #
  # Omission must not print a devnet authority on a mainnet build. This is the
  # half that would still be broken if the fix only read the env var — and,
  # since the SOLANA_SQUADS_VAULT_PDA key is ABSENT from both deployed apps, it
  # is the half that every production render and every production rake run
  # takes.

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
  # Holds for readers that do not exist yet: no application source may name
  # either cluster's Squads vault PDA as a literal. That is the exact mutation
  # this pair of tasks reverses, kept permanently armed. Modelled on the "no
  # view names Config::RPC_URL" guard in
  # test/integration/rpc_credential_not_in_browser_test.rb.
  #
  # WIDENED from ERB to Ruby and rake by vault-pda-readers-diverge. The ERB-only
  # form was the right scope for admin-shows-devnet-authority, because widening
  # it there would have gone RED on two live offenders
  # (app/controllers/admin/vault_init_controller.rb and lib/tasks/solana.rake)
  # that the view task had no business rewriting. Those two are fixed, so the
  # guard now covers every surface that could hold one.
  #
  # app/services/solana/config.rb is the one file EXEMPT — it is where the two
  # literals are defined. Excluding it by path rather than by pattern is
  # deliberate: a second exemption has to be added consciously.
  GUARDED_GLOBS = ["app/**/*.erb", "app/**/*.rb", "lib/**/*.rb", "lib/tasks/**/*.rake"].freeze
  LITERAL_HOME  = "app/services/solana/config.rb".freeze

  test "no application source hardcodes a Squads vault PDA" do
    root = Rails.root
    paths = GUARDED_GLOBS.flat_map { |glob| Dir[root.join(glob)] }.uniq
    relative = ->(path) { Pathname.new(path).relative_path_from(root).to_s }

    scanned = paths.reject { |path| relative.call(path) == LITERAL_HOME }

    # A glob that matched nothing would make the assertion below pass without
    # reading a line. Pin that the sweep actually reached both readers this
    # task fixed.
    %w[app/controllers/admin/vault_init_controller.rb lib/tasks/solana.rake].each do |expected|
      assert_includes scanned.map(&relative), expected,
        "the guard's globs no longer reach #{expected} — it would pass vacuously"
    end

    offenders = scanned.select do |path|
      contents = File.read(path)
      contents.include?(DEVNET) || contents.include?(MAINNET)
    end

    assert_empty offenders.map(&relative),
      "these files hardcode a cluster-specific Squads vault PDA — the upgrade authority " \
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
