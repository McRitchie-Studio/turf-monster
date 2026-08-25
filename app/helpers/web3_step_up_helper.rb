# View seam for the web3 step-up modal.
#
# THE CARD ITSELF IS THE ENGINE'S. studio-engine lifted it out of this app on
# 2026-08-21 (studio/modals/_web3_step_up) and generalized it behind locals; this
# app rendered its own second copy until 2026-08-24. What is left here is only
# the part the engine deliberately refuses to own — this app's words and this
# app's help route.
#
# It is a HELPER rather than two literal render calls because the card is
# registered TWICE: once in layouts/application (what a player meets) and once in
# layouts/modal_preview (the /admin/modals preview harness, which keeps its own
# registration list). Inlining the locals in both is how the two copies drifted
# the first time.
module Web3StepUpHelper
  # The engine default names "on-chain actions", which is accurate and says
  # nothing. Turf names the two things a player actually loses, because that is
  # the sentence that decides whether they press the button or bail.
  STEP_UP_SUBTEXT = "This account is secured by a Solana wallet. You are signed in, but this " \
                    "session can’t sign on-chain — so entering contests and moving funds " \
                    "still need your wallet.".freeze

  # Locals for `render "studio/modals/web3_step_up"`.
  #
  # Everything NOT set here is an engine default that already matches this app:
  # picker_modal_id (wallet-connect), modal_id (web3-step-up), modal_store
  # (modals), dismiss_event (web3-step-up-dismissed), heading, help_label.
  # Passing them again would only create a second place for them to drift.
  #
  # help_url is passed because the engine takes a STRING and this app has a route
  # helper. It is not decoration: the engine drops the help line entirely when
  # help_url is absent, and a self-custody wallet is the one credential this app
  # cannot reset for a user — a card with no way to reach a human strands a
  # legitimate owner who merely cannot get at their wallet right now.
  def web3_step_up_locals
    { subtext: STEP_UP_SUBTEXT, help_url: help_path }
  end
end
