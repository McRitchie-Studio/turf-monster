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
# query is pure SQL against the denormalized mirror and the partial index
# `index_users_on_pending_level_up_grants`, whose predicate is exactly this
# sweep's (`level > entry_tokens_granted_level`) and whose keys are exactly this
# sweep's ORDER BY (`entry_tokens_swept_at, id`). So a sweep with no fresh
# level-ups reads an empty index and issues ZERO Solana RPCs. Only a user who
# actually crossed a milestone costs the two reads (sync_balance +
# list_entry_tokens) that Tokens::LevelUpGrant spends verifying against the
# chain before it mints.
#
# BOUNDED AT BOTH ENDS. `BATCH_SIZE` users per run, and MAX_GRANTS_PER_RUN
# tokens per user inside the service. Public devnet rate-limits
# getProgramAccounts to roughly 1/sec/IP, and every mint spends admin SOL on
# rent — neither is something a cron should be able to consume without a
# ceiling. Whatever the ceiling defers is picked up 15 minutes later.
#
# THE BATCH ROTATES, so a stuck row cannot become an outage. Ordering by id
# meant the oldest ids were swept first EVERY run, and a user the sweep cannot
# evaluate (see Tokens::LevelUpGrant's unevaluable states) stays a candidate
# indefinitely — so a handful of permanently stuck low-id rows would occupy the
# batch and every user behind them would never be paid at all. `candidates` is
# therefore ordered by `entry_tokens_swept_at`, stamped on EVERY pass whatever
# the outcome, which sends a just-visited row to the back of the queue. The
# stamp records only that the row had its turn; the payment record is
# `entry_tokens_granted_level`, and that still advances on proof alone.
#
# NOTHING LEAVES THIS SWEEP QUIETLY. A user who cannot be evaluated, and a user
# whose pass raised, each get a named log line AND an ErrorLog — the sibling
# 15-minute cron directly above this one in config/schedule.yml
# (Deposits::OnchainReconciler) makes the same argument: a log line does not
# summon anyone, an ErrorLog does. A user who can never be paid must not be
# invisible.
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
    vault       = Solana::Vault.new
    minted      = 0
    unevaluable = 0
    failed      = 0

    candidates.each do |user|
      result = Tokens::LevelUpGrant.call(user, vault: vault)

      if result.evaluated?
        minted += result.minted_count
      else
        unevaluable += 1
        report_unevaluable(user, result)
      end
    rescue => e
      # One user's failure never ends the sweep — the rest of the queue is
      # owed their tokens just as much. But it is RECORDED, not shrugged off:
      # a wallet that faults on every run is a user who never gets paid.
      failed += 1
      Rails.logger.warn "[level-up-grant] user=#{user.id} sweep failed " \
                        "(#{e.class}: #{e.message.to_s[0, 140]})"
      capture_error(e, user)
    ensure
      # ROTATION, in `ensure` so it runs on every outcome INCLUDING a raise —
      # a wallet whose read raises every time is exactly the row that would
      # otherwise pin itself to the front of the batch forever. Never a claim
      # that anything was paid; see the migration's comment.
      stamp_swept(user)
    end

    Rails.logger.info "[level-up-grant] sweep.done users=#{candidates.length} " \
                      "minted=#{minted} unevaluable=#{unevaluable} failed=#{failed}"
  end

  # Users whose level has outrun the level they have been granted through,
  # least-recently-swept first.
  #
  # The mirror can only LAG the chain (seeds are monotonic and it is only ever
  # written from a chain read), so this misses nobody permanently: a user whose
  # seeds moved without a page load — an inviter credited by a referral, say —
  # is picked up on the sweep after their next hydrate, and the token is not
  # something they could see or spend before then anyway.
  #
  # The ORDER BY is load-bearing, not cosmetic: it is what guarantees every
  # candidate gets a turn regardless of how many rows ahead of it are stuck.
  # `index_users_on_pending_level_up_grants` is keyed to serve it directly.
  def self.candidates
    User
      .where("level > entry_tokens_granted_level")
      .where(
        "(web3_solana_address IS NOT NULL AND web3_solana_address != '') OR " \
        "(web2_solana_address IS NOT NULL AND web2_solana_address != '')"
      )
      .order(:entry_tokens_swept_at, :id)
  end

  private

  # A user the sweep could not reach a verdict on. Named in the log AND paged
  # via ErrorLog: they are owed a token the system currently cannot deliver, and
  # the condition (no UserAccount PDA at their address) does not heal itself.
  def report_unevaluable(user, result)
    message = "[level-up-grant] unevaluable user=#{user.id} " \
              "reason=#{result.unevaluable_reason} (#{result.unevaluable_message})"
    Rails.logger.warn message
    capture_error(UnevaluableUserError.new(message), user)
  end

  # Telemetry must never change control flow — a failure to record is logged and
  # swallowed so it cannot end a sweep the rest of the queue still needs.
  def capture_error(exception, user)
    log = ErrorLog.capture!(exception)
    log.target = user
    log.target_name = user.try(:slug)
    log.save!
  rescue StandardError => e
    Rails.logger.error "[level-up-grant] error_log_failed user=#{user&.id} " \
                       "#{e.class}: #{e.message}"
  end

  # Advances only the ROTATION cursor. Uses update_column for the same reason
  # the waterline does: a denormalized sweep mirror must not fire validations on
  # legacy rows. Guarded so a bookkeeping failure cannot abort the sweep.
  def stamp_swept(user)
    user.update_column(:entry_tokens_swept_at, Time.current)
  rescue StandardError => e
    Rails.logger.error "[level-up-grant] swept_stamp_failed user=#{user&.id} " \
                       "#{e.class}: #{e.message}"
  end

  # Raised nowhere — constructed purely to give ErrorLog a typed, greppable
  # class for the "owed but unpayable" condition, the way
  # Deposits::OnchainReconciler uses StrandedDepositError.
  class UnevaluableUserError < StandardError; end
end
