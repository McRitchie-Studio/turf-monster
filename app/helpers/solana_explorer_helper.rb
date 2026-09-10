# View seam for Solana explorer links.
#
# ONE PLACE OWNS THE CLUSTER, and that is the whole point of this file.
#
# The explorer link block itself is the engine's
# (studio/modals/blocks/_solana_tx_link). This app forked its own copy until
# 2026-08-25 for one stated reason: the fork computed the cluster inline from
# Solana::Config.devnet?, so no callsite COULD forget it. The engine's version
# takes cluster_param as a local defaulting to "" — which means a callsite that
# forgets it renders a MAINNET explorer link for a DEVNET transaction. The link
# resolves, looks correct, and shows nothing, which is worse than a broken link
# because it reads as "your transaction is missing".
#
# So the fork was deleted only once its safety had somewhere else to live. That
# is here: both callsites read the cluster from this helper, and
# test/integration/engine_modal_defork_test.rb fails if any callsite of the
# engine block omits cluster_param. The fork's guarantee was structural and
# untested; this one is asserted, which is why the trade is worth making.
module SolanaExplorerHelper
  # Query string appended to an explorer URL, empty on mainnet.
  #
  # Solana::Config.devnet? is the app's single source of truth for which cluster
  # this deploy talks to — the same predicate the RPC client, the faucet guards,
  # and the admin mint gate read. Deriving the link from it means the link can
  # never disagree with the transaction it points at.
  def solana_explorer_cluster_param
    Solana::Config.devnet? ? "?cluster=devnet" : ""
  end
end
