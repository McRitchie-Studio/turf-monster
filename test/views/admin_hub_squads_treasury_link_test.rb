require "test_helper"

# [integration] The Link Hub's way OUT to the Squads treasury.
#
# WHY THIS PAGE OWES A TEST AT ALL. Collecting operator revenue is two hops. Hop
# 1 sweeps the op_rev account into the treasury and this app performs it
# (/admin/pending_transactions). Hop 2 moves those funds onward, and NOTHING in
# turf-monster or turf-vault performs or prepares it — app.squads.so is the only
# route. So this link is not a convenience; it is the only handle on the second
# half of getting paid, and a wrong one reads as authoritative in the exact spot
# an operator consults.
#
# WHAT IT PINS, AND WHAT A WEAKER TEST WOULD HAVE MISSED. The builder used to
# interpolate the Squads MULTISIG address, which 404s — app.squads.so resolves a
# Squad by its VAULT PDA and wants the `/home` suffix (measured in a browser
# 2026-09-29, both directions). A test that asserted only the `app.squads.so`
# host, or compared the href to `Solana::Config.squads_app_url` itself, passes
# against that broken form: the first is true of the 404 and the second is a
# tautology. So every assertion here names the vault PDA, the suffix, or the
# multisig's ABSENCE — the three facts the old form cannot satisfy.
#
# AND IT RENDERS BOTH CLUSTERS. A devnet-only assertion passes against a page
# that hardcodes the mainnet Squad, and the reverse; the cluster travels in the
# ADDRESS here (`devnet.squads.so` is decommissioned), so the address is the
# whole of the cluster correctness. Same technique as
# test/integration/contract_upgrade_authority_test.rb: NETWORK is a load-time
# constant, and swapping it is the only way to put this process on the other
# cluster. Rails parallelises by fork, so it never crosses workers.
class AdminHubSquadsTreasuryLinkTest < ActionDispatch::IntegrationTest
  DEVNET_VAULT   = Solana::Config::DEVNET_SQUADS_VAULT_PDA
  MAINNET_VAULT  = Solana::Config::MAINNET_SQUADS_VAULT_PDA
  DEVNET_MULTI   = Solana::Config::DEVNET_SQUADS_MULTISIG
  MAINNET_MULTI  = Solana::Config::MAINNET_SQUADS_MULTISIG

  setup { log_in_as(users(:alex)) } # admin — the hub is admin-gated

  def with_network(network)
    previous = Solana::Config::NETWORK
    Solana::Config.send(:remove_const, :NETWORK)
    Solana::Config.const_set(:NETWORK, network)
    yield
  ensure
    Solana::Config.send(:remove_const, :NETWORK)
    Solana::Config.const_set(:NETWORK, previous)
  end

  # The cluster DEFAULT is what both deployed apps take — the
  # SOLANA_SQUADS_VAULT_PDA key is absent from turf-monster-mainnet and
  # turf-monster-qa alike — so a developer's local override must not decide what
  # these assertions read.
  def without_vault_override
    previous = ENV["SOLANA_SQUADS_VAULT_PDA"]
    ENV.delete("SOLANA_SQUADS_VAULT_PDA")
    yield
  ensure
    previous.nil? ? ENV.delete("SOLANA_SQUADS_VAULT_PDA") : ENV["SOLANA_SQUADS_VAULT_PDA"] = previous
  end

  # Both halves are required. The positive alone would pass against a page that
  # also offered the other cluster's Squad; the negative alone would pass
  # against a page that stopped rendering the section at all.
  def assert_squad_link(vault:, absent_vault:, cluster:)
    get admin_hub_path
    assert_response :success

    expected = "https://app.squads.so/squads/#{vault}/home"
    hrefs = css_select("a[href^='https://app.squads.so']").map { |a| a["href"] }

    assert hrefs.any?, "#{cluster}: the hub offered no Squads link at all — " \
      "the negative assertions below would pass vacuously"
    assert_equal [expected], hrefs.uniq,
      "#{cluster}: every Squads link must be the cluster's vault PDA plus /home"
    assert_not_includes response.body, absent_vault,
      "#{cluster}: the OTHER cluster's Squads vault PDA appears on the hub"
    [DEVNET_MULTI, MAINNET_MULTI].each do |multisig|
      assert_not_includes response.body, multisig,
        "#{cluster}: a MULTISIG address on the hub means a link that 404s"
    end
    hrefs
  end

  test "a devnet build links out to the DEVNET Squad home" do
    without_vault_override do
      with_network("devnet") { assert_squad_link(vault: DEVNET_VAULT, absent_vault: MAINNET_VAULT, cluster: "devnet") }
    end
  end

  test "a mainnet build links out to the MAINNET Squad home" do
    without_vault_override do
      with_network("mainnet-beta") do
        assert_squad_link(vault: MAINNET_VAULT, absent_vault: DEVNET_VAULT, cluster: "mainnet-beta")
      end
    end
  end

  # TWO TILES, ONE SQUAD, ON PURPOSE — pinned so a later reader does not "fix"
  # it as a duplicate. The Squad home serves two unrelated operator jobs and
  # they start in two different places on this page: moving swept revenue, in
  # the Hub section beside the sweep it follows, and changing program-upgrade
  # membership, under Signing and Multisig. Mr. McRitchie had to hunt for the
  # money one when only the membership one existed.
  test "the money hop and the membership hop each get their own tile" do
    without_vault_override do
      with_network("devnet") do
        hrefs = assert_squad_link(vault: DEVNET_VAULT, absent_vault: MAINNET_VAULT, cluster: "devnet")
        assert_equal 2, hrefs.length,
          "the hub carries one Squads tile for the treasury and one for membership"
      end
    end
  end

  # The address alone is a string an operator has to recognise. The LABEL is
  # what makes the tile findable, and findability is the whole defect: the link
  # existed, filed under membership, and was not found by someone moving money.
  test "the treasury tile says it is the way to move swept revenue out" do
    without_vault_override do
      with_network("mainnet-beta") do
        get admin_hub_path
        assert_response :success

        tiles = css_select("a[href^='https://app.squads.so']").map { |a| a.text.squish }
        treasury = tiles.find { |text| text.match?(/Squads Treasury/) }

        assert treasury, "no tile is labelled for the treasury; tiles were #{tiles.inspect}"
        assert_match(/revenue/i, treasury, "the note should name what the operator is moving")
        assert_match(/mainnet-beta/, treasury, "the note must name the cluster it serves")
      end
    end
  end

  # External by construction: it leaves the app. A same-tab link out of an admin
  # console loses the operator's place mid-task.
  test "the Squads tiles open in a new tab" do
    without_vault_override do
      with_network("devnet") do
        get admin_hub_path
        assert_response :success

        links = css_select("a[href^='https://app.squads.so']")
        assert links.any?
        links.each do |link|
          assert_equal "_blank", link["target"]
          assert_includes link["rel"].to_s, "noopener"
        end
      end
    end
  end
end
