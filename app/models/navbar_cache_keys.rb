# The per-user Rails.cache keys behind the navbar's balance and seeds readouts.
#
# ApplicationController reads and clears them for the browser. An entry made
# through the agent API moves the same balances, so Entries::PostEntryEffects
# clears the same keys; both spell them through here so the two cannot drift.
module NavbarCacheKeys
  module_function

  def seeds(user) = "user_seeds:#{user.id}"
  def usdc(user)  = "usdc_balance:#{user.id}"
  def usdt(user)  = "usdt_balance:#{user.id}"

  # Everything an entry can have moved: seeds earned, and USDC or USDT spent.
  def after_entry(user) = [seeds(user), usdc(user), usdt(user)]
end
