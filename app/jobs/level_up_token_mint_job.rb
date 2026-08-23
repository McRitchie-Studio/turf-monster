# Pays out the free-entry token every level milestone promises.
#
# A trusted, fresh seed snapshot nudges this job immediately so the token can
# land while the level-up celebration is still on screen. The 15-minute cron
# (config/schedule.yml, sidekiq-cron) remains the recovery path for a missed
# enqueue, an RPC outage, or seeds earned outside a request Turf Monster sees.
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

  # Coalesce repeated hydrates for the same outstanding milestone while the
  # targeted job is queued/running. The deterministic on-chain PDA remains the
  # hard double-grant guard; this short lease only avoids needless overlapping
  # RPCs and expected init collisions. A cache outage fails open because the
  # payout is more important than this optimization.
  NUDGE_LEASE = 2.minutes

  def self.nudge(user, seeds_total:)
    return false unless user&.solana_connected?

    seeds_total = Integer(seeds_total)
    level = User.level_for(seeds_total)
    user.update_level_from_seeds!(seeds_total)
    return false unless level > user.entry_tokens_granted_level

    key = nudge_cache_key(user.id, level)
    claimed = Rails.cache.write(key, true, expires_in: NUDGE_LEASE, unless_exist: true)
    return false if claimed == false

    perform_later(user_id: user.id)
    true
  rescue ArgumentError, TypeError
    false
  rescue => e
    Rails.cache.delete(key) if defined?(key) && key
    Rails.logger.warn "[level-up-grant] nudge_failed user=#{user&.id} " \
                      "(#{e.class}: #{e.message.to_s[0, 140]})"
    false
  end

  def self.nudge_cache_key(user_id, level)
    "level-up-token-nudge/v1/#{user_id}/#{level}"
  end

  def perform(batch_size: BATCH_SIZE, user_id: nil)
    # Catches a stale Sidekiq env pointing at a dead PROGRAM_ID — the
    # mint-to-wrong-program bug that has bitten twice on devnet redeploys.
    # Raises only on a definitive "that program does not exist"; transient RPC
    # trouble falls through and lets the mint surface its own error.
    Solana::Vault.ensure_program_id_live! unless ENV["SKIP_PROGRAM_ID_LIVE_CHECK"] == "true"

    return perform_target(user_id) if user_id

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
      result = grant_user(user, vault: vault)

      if result.nil?
        failed += 1
      elsif result.evaluated?
        minted += result.minted_count
      else
        unevaluable += 1
      end
    end

    Rails.logger.info "[level-up-grant] sweep.done users=#{candidates.length} " \
                      "minted=#{minted} unevaluable=#{unevaluable} failed=#{failed}"
  end

  # Users whose level has outrun the level they have been granted through,
  # least-recently-swept first.
  #
  # The mirror can only LAG the chain (seeds are monotonic and it is only ever
  # written from a chain read), so this misses nobody permanently. A hydrate
  # with a fresh snapshot uses `nudge` instead; the sweep catches missed
  # request paths and transient enqueue failures.
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

  # Bypasses the SQL candidate mirror. The fresh request-path seed snapshot is
  # only the trigger; Tokens::LevelUpGrant still re-reads chain truth before it
  # mints, so a stale or malformed snapshot can never award a token by itself.
  def perform_target(user_id)
    user = User.find_by(id: user_id)
    return unless user

    nudged_level = user.level
    Rails.logger.info "[level-up-grant] target.start user=#{user.id} level=#{nudged_level}"
    result = grant_user(user, vault: Solana::Vault.new)
    Rails.logger.info "[level-up-grant] target.done user=#{user.id} " \
                      "minted=#{result&.minted_count || 0} evaluated=#{result&.evaluated? || false}"
    result
  ensure
    if defined?(user) && user && defined?(nudged_level) && nudged_level
      Rails.cache.delete(self.class.nudge_cache_key(user.id, nudged_level))
    end
  end

  # One user's failure never ends the sweep — the rest of the queue is owed
  # their tokens too. Targeted runs share the same reporting and rotation
  # semantics, while the scheduled caller decides how to count the result.
  def grant_user(user, vault:)
    result = Tokens::LevelUpGrant.call(user, vault: vault)
    report_unevaluable(user, result) unless result.evaluated?
    result
  rescue => e
    Rails.logger.warn "[level-up-grant] user=#{user.id} grant failed " \
                      "(#{e.class}: #{e.message.to_s[0, 140]})"
    capture_error(e, user)
    nil
  ensure
    # ROTATION, in `ensure` so it runs on every outcome INCLUDING a raise — a
    # wallet whose read raises every time is exactly the row that would
    # otherwise pin itself to the front of the batch forever. Never a claim
    # that anything was paid; see the migration's comment.
    stamp_swept(user)
  end

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
