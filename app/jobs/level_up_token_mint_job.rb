# Pays out the free-entry token every level milestone promises.
#
# The level-up modal tells the user their token "will arrive in 48 hours". Until
# this job existed, that sentence was underwritten by nothing: no scheduled work
# minted level-up tokens, and the only thing that ever did was an operator
# opening /admin/free_entries and clicking Mint. This job is what makes those 48
# hours a deadline the system meets by itself. It runs every 15 minutes
# (config/schedule.yml, sidekiq-cron), so the real latency is a quarter hour.
#
# CHEAP WHEN THERE IS NOTHING TO DO — which is almost always. The candidate
# query is pure SQL against the denormalized mirror and its partial index
# (`level > entry_tokens_granted_level`), so a sweep with no fresh level-ups
# issues ZERO Solana RPCs. Only a user who actually crossed a milestone costs
# the two reads (sync_balance + list_entry_tokens) that Tokens::LevelUpGrant
# spends verifying against the chain before it mints.
#
# BOUNDED AT BOTH ENDS. `BATCH_SIZE` users per run, and MAX_GRANTS_PER_RUN
# tokens per user inside the service. Public devnet rate-limits
# getProgramAccounts to roughly 1/sec/IP, and every mint spends admin SOL on
# rent — neither is something a cron should be able to consume without a
# ceiling. Whatever the ceiling defers is picked up 15 minutes later.
#
# The sweep is SAFE TO RUN TWICE, overlapping, or after a crash: the grant's
# source_ref is deterministic, so the on-chain `init` constraint — not any
# bookkeeping here — is what makes a double-grant impossible. See
# Tokens::LevelUpGrant for that argument in full.
class LevelUpTokenMintJob < ApplicationJob
  queue_as :default

  # Users per sweep. 25 × 2 RPCs is a comfortable fit inside a 15-minute window
  # even at devnet's ~1/sec, and only levelled-up users are ever counted.
  BATCH_SIZE = 25

  def perform(batch_size: BATCH_SIZE)
    # Catches a stale Sidekiq env pointing at a dead PROGRAM_ID — the
    # mint-to-wrong-program bug that has bitten twice on devnet redeploys.
    # Raises only on a definitive "that program does not exist"; transient RPC
    # trouble falls through and lets the mint surface its own error.
    Solana::Vault.ensure_program_id_live! unless ENV["SKIP_PROGRAM_ID_LIVE_CHECK"] == "true"

    candidates = self.class.candidates.limit(batch_size).to_a
    return if candidates.empty?

    Rails.logger.info "[level-up-grant] sweep.start candidates=#{candidates.length}"

    # ONE vault for the sweep — it carries the RPC client and the 5-minute
    # program-id cache, so a per-user instance would re-pay that setup 25 times.
    vault  = Solana::Vault.new
    minted = 0

    candidates.each do |user|
      result = Tokens::LevelUpGrant.call(user, vault: vault)
      minted += result.minted_count if result
    rescue => e
      # One user's failure never ends the sweep — the rest of the queue is
      # owed their tokens just as much.
      Rails.logger.warn "[level-up-grant] user=#{user.id} sweep failed " \
                        "(#{e.class}: #{e.message.to_s[0, 140]})"
    end

    Rails.logger.info "[level-up-grant] sweep.done users=#{candidates.length} minted=#{minted}"
  end

  # Users whose level has outrun the level they have been granted through.
  # Matches the partial index added with `entry_tokens_granted_level`.
  #
  # The mirror can only LAG the chain (seeds are monotonic and it is only ever
  # written from a chain read), so this misses nobody permanently: a user whose
  # seeds moved without a page load — an inviter credited by a referral, say —
  # is picked up on the sweep after their next hydrate, and the token is not
  # something they could see or spend before then anyway.
  def self.candidates
    User
      .where("level > entry_tokens_granted_level")
      .where(
        "(web3_solana_address IS NOT NULL AND web3_solana_address != '') OR " \
        "(web2_solana_address IS NOT NULL AND web2_solana_address != '')"
      )
      .order(:id)
  end
end
