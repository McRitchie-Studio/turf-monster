# frozen_string_literal: true

require "test_helper"

# [component] card-claims-program-invariance — the admin deployment-state card's
# PROGRAM ID caption must name the cluster this build runs on.
#
# THE BUG. The caption read "Same on devnet + mainnet builds — pinned via
# SOLANA_PROGRAM_ID." The two clusters run DIFFERENT programs, measured on the
# app's own committed IDLs:
#
#   config/turf_vault.idl.json          -> EQGFJAcABtDb6VXtiijTjZ6cE2UqdvhnqJvoharJbpMJ  (devnet)
#   config/turf_vault.mainnet.idl.json  -> DaFv83yokwTz8msP9CzJ13eazSGk15NuUTxjkfzJzxMM  (mainnet)
#
# Solana::Config::IDL_PATH is keyed on NETWORK precisely BECAUSE they differ.
# This is the admin card an operator consults BEFORE proposing a program
# upgrade, so it was denying a cluster distinction to the one reader whose next
# action depends on it. It dated to the page's first commit (23cdb09e) and
# survived five PRs on this card because NOTHING GUARDED THE LINE.
#
# WHY THIS TEST RENDERS RATHER THAN GREPS. The guards this card already had for
# its copy are scans over the ERB SOURCE. A source scan passes on a card that
# has stopped emitting the caption altogether, and it cannot see whether the
# value it names is the one the running build resolved. So every case here
# drives the REAL page through the REAL controller, twice, once per cluster
# configuration, and reads the caption out of the rendered body.
#
# WHY IT DRIVES BOTH CLUSTERS. A suite that only asserts "mainnet-beta" passes
# against a caption that hardcodes "mainnet-beta" — the same class of defect
# with a different literal. Asserting the two renders DIFFER is what makes the
# caption's dependence on the config the thing under test.
#
# WHAT THE SETUP MUST NOT DO. `with_network` swaps the cluster and nothing else.
# It does not install the caption, the cluster name, or the difference being
# asserted — a setup that supplied any of those would certify the unfixed
# caption green.
#
# SCOPED TO A data-test SUBTREE. The contract page also carries a navbar, a
# footer and meta tags; a body-wide match reads all of them. The extractor
# returns nil when the card did not render, so the negative assertions cannot
# pass vacuously.
class ContractProgramIdCaptionTest < ActionDispatch::IntegrationTest
  DEVNET  = "devnet"
  MAINNET = "mainnet-beta"

  # The one caption under test, by its data-test hook.
  def program_id_caption(body)
    body[%r{<p[^>]*data-test="program-id-caption"[^>]*>(.*?)</p>}m, 1]&.strip
  end

  # NETWORK is a LOAD-TIME constant (deliberately — see the OPSEC-012 comment in
  # config.rb), so swapping the constant is the only way to put this process on
  # the other cluster. Same technique, and the same fork-isolation argument, as
  # ContractUpgradeAuthorityTest's `with_network`; Rails parallelises by FORK,
  # so it never crosses workers.
  def with_network(network)
    previous = Solana::Config::NETWORK
    Solana::Config.send(:remove_const, :NETWORK)
    Solana::Config.const_set(:NETWORK, network)
    yield
  ensure
    Solana::Config.send(:remove_const, :NETWORK)
    Solana::Config.const_set(:NETWORK, previous)
  end

  def caption_on(network)
    with_network(network) do
      get contract_path
      assert_response :success

      caption = program_id_caption(response.body)
      assert caption.present?,
        "SOLANA_NETWORK=#{network}: the admin deployment-state card rendered no Program ID " \
        "caption — every assertion about its text would pass vacuously"
      caption
    end
  end

  setup { log_in_as(users(:alex)) }

  # --- the claim the task exists to establish ---

  test "the Program ID caption differs between a devnet build and a mainnet build" do
    devnet  = caption_on(DEVNET)
    mainnet = caption_on(MAINNET)

    assert_not_equal devnet, mainnet,
      "the Program ID caption renders identically on both clusters. devnet and mainnet run " \
      "DIFFERENT programs (config/turf_vault.idl.json vs config/turf_vault.mainnet.idl.json), " \
      "so a caption that cannot tell them apart is stating a false invariance on the page an " \
      "operator reads before proposing an upgrade."
  end

  test "each cluster's caption names its OWN cluster and not the other" do
    assert_match(/\bdevnet\b/, caption_on(DEVNET),
      "SOLANA_NETWORK=devnet: the caption must name the cluster this build runs on")
    assert_no_match(/mainnet-beta/, caption_on(DEVNET),
      "SOLANA_NETWORK=devnet: the caption names the OTHER cluster")

    assert_match(/mainnet-beta/, caption_on(MAINNET),
      "SOLANA_NETWORK=mainnet-beta: the caption must name the cluster this build runs on")
  end

  # The exact sentence this task removes, kept permanently armed. Stated
  # separately from the difference assertion above because a caption could be
  # made cluster-dependent while still carrying the false invariance beside it.
  test "the caption never claims the program is the same across builds" do
    [DEVNET, MAINNET].each do |network|
      caption = caption_on(network)
      assert_no_match(/same on devnet/i, caption,
        "SOLANA_NETWORK=#{network}: the caption claims the program ID is the same on both " \
        "clusters. It is not — EQGFJAc…bpMJ on devnet, DaFv83yo…zxMM on mainnet.")
      assert_match(/per cluster/i, caption,
        "SOLANA_NETWORK=#{network}: the caption must say the program ID is per cluster, which " \
        "is the fact an operator needs before proposing an upgrade")
    end
  end

  # The card is admin-only. Also pins that the extractor is finding an
  # admin-gated caption rather than something rendered for everyone — without
  # this, the assertions above would be equally satisfied by a public element.
  test "a non-admin sees no Program ID caption at all" do
    log_in_as(users(:jordan))
    get contract_path
    assert_response :success
    assert_nil program_id_caption(response.body),
      "the deployment-state card is admin-only"
  end
end
