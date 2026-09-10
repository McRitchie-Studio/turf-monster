# View seam for the web3 step-up modal.
#
# THE CARD ITSELF IS THE GEM'S. studio-engine lifted it out of this app on
# 2026-08-21 and generalized it behind locals; this app rendered its own second
# copy until 2026-08-24; then /tasks/turf-rides-gem-modals moved the partial on
# to solana-studio (solana_studio/modals/_web3_step_up), which is where it lives
# now. What is left here is only the part the shared card deliberately refuses to
# own — this app's help route.
#
# AND AS OF 2026-09-06 THAT IS ALL THAT IS LEFT. This app also passed its own
# `subtext:`, and that override is exactly how a copy change failed to reach a
# player: solana-studio cut the card's body from four lines to one, and this app
# went on rendering its four-line fork — so the shared default changed, the
# player-facing card did not, and the card gained an address line on top of the
# long copy. MORE words, not fewer. The override is gone. The card's words are
# the gem's words, and the next copy change arrives here by bumping the lock
# rather than by editing this file.
#
# It is a HELPER rather than a literal render call because the card was
# registered TWICE — once in layouts/application (what a player meets) and once
# in layouts/modal_preview, the admin preview harness, which kept its own
# registration list. Inlining the locals in both is how the two copies drifted
# the first time. The harness was deleted on 2026-09-09; the helper stays because
# what it prevents is a SECOND inline copy, and the cost of keeping it is one
# indirection.
module Web3StepUpHelper
  # Locals for `render "solana_studio/modals/web3_step_up"`.
  #
  # Everything NOT set here is a gem default that already matches this app:
  # subtext, picker_modal_id (wallet-connect), modal_id (web3-step-up),
  # modal_store (modals), dismiss_event (web3-step-up-dismissed), heading and
  # help_label. Passing any of them again would only create a second place for
  # them to drift, which is the failure this file has now had twice.
  #
  # help_url is passed because the gem takes a STRING and this app has a route
  # helper. It is not decoration: the gem drops the help line entirely when
  # help_url is absent, and a self-custody wallet is the one credential this app
  # cannot reset for a user — a card with no way to reach a human strands a
  # legitimate owner who merely cannot get at their wallet right now.
  def web3_step_up_locals
    { help_url: help_path }
  end
end
