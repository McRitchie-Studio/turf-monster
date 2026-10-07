# The account freeze (OPSEC-048): one vocabulary for every surface that refuses
# a frozen account. An app-level hold, not an on-chain one: the tokens a frozen
# account already holds stay where they are, and this app stops acting for it.
#
#   FrozenAccountGuard          controllers: every non-GET, web and agent API
#   FrozenAccount::Validation   models: where an entry, a pick, a chat line, a
#                               reaction, a username or a wallet link lands
#   AccountFreezeEvent          the audit trail of every freeze and unfreeze
#
# docs/AGENT_API.md documents the code and status for agents.
module FrozenAccount
  CODE    = "account_frozen".freeze
  STATUS  = :forbidden # 403
  MESSAGE = "Your account is frozen. Contact support@turfmonster.media.".freeze

  # The banner's sentence and the reason a disabled button gives. The banner
  # shows BANNER_DETAIL from the sm breakpoint up only, so a phone's sticky
  # header carries the headline and the contact, not four wrapped lines.
  BANNER_HEADLINE = "Your account is frozen.".freeze
  BANNER_DETAIL   = "You can look around, but you cannot enter, chat or change your account.".freeze
  BANNER          = "#{BANNER_HEADLINE} #{BANNER_DETAIL}".freeze
  CTA_REASON = "Your account is frozen".freeze
  # The toast title where a frozen account's tap is refused (pick tile, reaction).
  TOAST_TITLE = "Account frozen".freeze
end
