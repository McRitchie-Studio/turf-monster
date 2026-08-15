# The 25-seed newsletter welcome bonus, in ONE place because it now has TWO
# callers.
#
# It lived as a private method on NewsletterController, which was right while
# /account was the only way to join. The shared /profile page can subscribe too,
# and the engine reaches this app through Studio.after_newsletter_change — a
# lambda in an initializer, which cannot call a private controller method. The
# alternative was a second copy, and a second copy of a reward drifts: the
# amount, the kind, or the rescue changes in one and not the other, and nobody
# notices until someone is paid twice or not at all.
#
# SEMANTICS ARE UNCHANGED from the controller version. This is a move, not a
# rewrite:
#
#   * nothing happens without a connected wallet — there is nowhere to grant to
#   * the AMOUNT comes from the on-chain season config (seeds_for_quest), not
#     from a constant here, so a season that changes the reward changes it
#   * every failure is swallowed and logged
#
# THAT LAST ONE IS DELIBERATE AND WORTH KEEPING. The grant goes over RPC to a
# chain that is sometimes unreachable, and the SUBSCRIPTION is the durable fact —
# a failed bonus must never cost someone their place on the mailing list. The
# real once-ever guard is the on-chain SeedGrant[newsletter] PDA, which refuses a
# second grant no matter how many times this is called, so a deferred grant stays
# backfillable and a repeated one is harmless.
class NewsletterSeedGrant
  KIND = :newsletter

  def self.call(user)
    new(user).call
  end

  def initialize(user)
    @user = user
  end

  # Returns the StateFanout 'seeds' payload so a caller that wants to animate the
  # tick-up can, or nil when the grant did not run. Nil is not an error — it is
  # "no wallet yet" or "the chain was unreachable", both of which are recoverable.
  def call
    return nil unless @user.solana_connected?

    vault = Solana::Vault.new
    result = vault.grant_seeds(
      wallet_address: @user.solana_address, amount: vault.seeds_for_quest(KIND), kind: KIND
    )
    {
      seeds_earned: result[:seeds_earned],
      seeds_total:  result[:seeds_total],
      seeds_level:  result[:seeds_level]
    }
  rescue => e
    Rails.logger.warn "[quest][newsletter] seed grant deferred for user=#{@user.id} " \
                      "(#{e.class}: #{e.message.to_s[0, 140]})"
    nil
  end
end
