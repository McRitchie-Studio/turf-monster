# Locals for the username card, which is the engine's
# (studio/modals/blocks/_change_username).
#
# The rename always rendered from the engine block; until studio-engine 0.114.0
# the two refusals did not, so modals/_username carried them as ERB branches.
# 0.114.0's `locked:` local draws a refusal, and this app only decides which one
# (turf-readopts-engine-modals). The decision stays here because it is product
# policy the engine must not own:
#
#   frozen account     OPSEC-048. User validation and FrozenAccountGuard refuse
#                      the write; this only stops the card offering it.
#   no contest entered User#can_change_username?, mirrored server-side in
#                      AccountsController#update_username. The CTA goes to the
#                      admin-set main contest (main_contest_target) so the click
#                      lands somewhere the rename unlocks from.
#   open               the on-chain rename: TM owns the save as callbacks
#                      (submit_url, finalize_hook, finalize_url, saved_event), and
#                      leveling: false keeps TM's quest-success beat authoritative.
#                      shared/_username_rename_intent explains the finalize hook.
module UsernameModalHelper
  def username_modal_locals
    locals = { current_username: current_user.username }

    if account_frozen?
      locals.merge(locked: {
        title: "Username locked",
        subtitle: "#{FrozenAccount::CTA_REASON}, so you cannot change your username."
      })
    elsif current_user.can_change_username?
      # NAMES NO WALLET. The rename runs through walletOps, which reaches Phantom,
      # Solflare or Backpack, and on a phone opens the wallet app. phantom_wallet?
      # still names the self-custodied branch correctly.
      wallet_line = current_user.phantom_wallet? ? "Saving opens your wallet to sign." : "Changes are saved via your managed wallet."
      locals.merge(
        submit_url:    update_username_account_path,
        finalize_url:  confirm_username_account_path,
        finalize_hook: "tmUsernameFinalize",
        saved_event:   "studio:username-saved",
        leveling:      false,
        description:   "Your username is stored on-chain. #{wallet_line}"
      )
    else
      target = main_contest_target
      locals.merge(locked: {
        title: "Enter Contest First",
        subtitle: "Your username is locked until you've played at least one contest. Submit an entry and the rename is unlocked for good.",
        cta_label: target ? "Enter #{target.name}" : "Browse Contests",
        cta_href: target ? contest_path(target) : contests_path
      })
    end
  end
end
