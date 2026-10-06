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

  # The banner's sentence and the reason a disabled button gives.
  BANNER     = "Your account is frozen. You can look around, but you cannot enter, chat or change your account.".freeze
  CTA_REASON = "Your account is frozen".freeze
end
