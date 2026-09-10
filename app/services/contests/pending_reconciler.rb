# Converge stranded `pending` Contest rows against the chain.
#
# WHAT STRANDS ONE. ContestsController#finalize writes the Contest row FIRST
# (`status: :pending`, carrying the derived PDA), broadcasts `create_contest`,
# stamps the returned signature, verifies the transaction, and only then
# promotes the row to `open`. That ordering (PR #551) inverted the failure mode
# on purpose: a crash used to leave MONEY WITH NO ROW, which no reconciler could
# reach because Entries::OnchainReconciler is rooted in Contest rows; it now
# leaves A ROW WITH NO MONEY, which is sweepable. This service is the sweep.
# Until it existed, "sweepable" was a property nothing exercised.
#
# THE DECISION, and why it is existence and not a balance:
#
#   PDA PRESENT  → PROMOTE to `open`. `create_contest` is ONE instruction and
#     Solana applies it atomically: turf-vault's create_contest.rs `init`s the
#     Contest PDA, `init`s the per-contest prize_pool token account, and CPIs
#     the creator's USDC transfer into it, all in the same handler. There is no
#     interleaving in which the account exists but the transfer did not run, so
#     the account existing IS the funding proof.
#
#     This is also why "and is funded" must NOT be re-tested as `prize_pool > 0`.
#     create_contest's validation #5 requires `any_fee_set || prize_pool > 0` —
#     a fee-charging contest with a ZERO prize pool is legal on chain. Gating the
#     promote on a positive pool would delete a real, funded, entry-taking
#     contest and strand its PDA exactly the way PR #551 set out to prevent.
#     The pool is read for the log line as evidence, never as a gate.
#
#   PDA ABSENT   → DELETE the row. The broadcast never landed, so no lamport
#     moved and nothing on chain refers to this slug. The row is pure squat: it
#     holds a uniquely-indexed slug its creator cannot reuse, and it is the only
#     thing standing between that creator and a clean retry.
#
#   PDA UNKNOWN  → LEAVE IT. An RPC fault is not evidence of absence. This is
#     the one place this service deliberately differs from
#     Entries::OnchainReconciler#onchain_account_exists?, which folds an RPC
#     error into "absent" — safe there, because the consequence is a SKIP. Here
#     the absent branch DELETES, so folding an error into it would let a rate
#     limit destroy a funded contest's only row. Errors skip; the next sweep
#     asks again.
#
#   UNRESOLVABLE → FLAG. Two rows must never be auto-deleted even with an absent
#     PDA: one whose stored `onchain_contest_id` does not match the PDA derived
#     from its slug (the identity is broken, so "absent" describes an address we
#     cannot attribute to this row), and one carrying an `onchain_tx_signature`
#     (something recorded a landed broadcast; a human reads the chain, not a
#     sweeper). Flagged rows are stamped `onchain_reconcile_flagged_at`, alert
#     once, and are then left alone.
#
# GUARDRAIL — READ-ONLY ON CHAIN. This service never signs, never broadcasts,
# never transfers, and never calls create_contest. It reads account state and
# writes Rails rows. Mirrors Deposits::OnchainReconciler (service + thin job +
# sidekiq-cron entry).
module Contests
  class PendingReconciler
    # Synthetic error carried into ErrorLog.capture! so an unresolvable strand
    # pages a human the same way a caught exception would (DB row + Sentry).
    class StrandedContestError < StandardError; end

    # Rows younger than this are still plausibly IN FLIGHT — a finalize sitting
    # between its write-ahead save and its promote is indistinguishable from a
    # strand by inspection, and the whole window (cosign, simulate, broadcast,
    # confirm, read-back verify, S3 banner) lives inside one request. Deleting a
    # live one would re-create the precise failure PR #551 removed: the finalize
    # would broadcast against a row that no longer exists.
    #
    # PROMOTING a live one is harmless by contrast — finalize's own STEP 5
    # `update!(status: :open)` is then a no-op — but the same threshold gates
    # both, because a row this young has nothing to gain from either verdict.
    RECONCILE_AFTER = 10.minutes

    def self.run(older_than: RECONCILE_AFTER, vault: Solana::Vault.new)
      new(vault: vault).run(older_than: older_than)
    end

    def self.reconcile(contest, vault: Solana::Vault.new)
      new(vault: vault).reconcile(contest)
    end

    def initialize(vault: Solana::Vault.new)
      @vault = vault
    end

    # Sweep every aged, unflagged pending contest. Returns a counts hash
    # ({ promoted:, deleted:, flagged:, skipped:, error: }).
    def run(older_than: RECONCILE_AFTER)
      cutoff = older_than.ago
      scope = Contest.where(status: :pending)
                     .where("contests.created_at < ?", cutoff)
                     .where(onchain_reconcile_flagged_at: nil)
      stats = Hash.new(0)
      scope.find_each { |contest| stats[reconcile(contest, cutoff: cutoff)] += 1 }
      Rails.logger.info(
        "[contest_reconciler] checked=#{stats.values.sum} promoted=#{stats[:promoted]} " \
        "deleted=#{stats[:deleted]} flagged=#{stats[:flagged]} skipped=#{stats[:skipped]} " \
        "errors=#{stats[:error]} cutoff=#{cutoff.iso8601}"
      )
      stats
    end

    # Reconcile one contest. Returns :promoted / :deleted / :flagged / :skipped
    # / :error. Safe to call directly (the age and status gates are re-checked
    # here, not just in the sweep scope).
    def reconcile(contest, cutoff: RECONCILE_AFTER.ago)
      return :skipped if contest.nil?

      contest.reload
      return :skipped unless contest.pending?
      return :skipped if contest.onchain_reconcile_flagged_at.present?
      return :skipped if contest.created_at > cutoff

      # A pending row with no PDA never reached finalize's write-ahead save (it
      # is a console/seed row left at the column default, which is "pending").
      # There is no chain address to ask about, so there is nothing this service
      # can prove either way.
      if contest.onchain_contest_id.blank?
        return flag!(contest, "row is `pending` with no onchain_contest_id — not a finalize strand; " \
                              "resolve by hand (promote it, or delete it if it was never meant to exist)")
      end

      derived = derived_pda(contest)
      unless derived == contest.onchain_contest_id
        return flag!(contest, "stored PDA #{contest.onchain_contest_id} does not match the PDA derived " \
                              "from slug #{contest.slug} (#{derived}) — identity is broken, refusing to act")
      end

      case pda_state(derived)
      when :present
        promote!(contest, derived)
      when :absent
        delete_or_flag!(contest, derived)
      else # :unknown — an RPC fault. Never read as absence; ask again next sweep.
        Rails.logger.info("[contest_reconciler][skip] #{contest.slug} on-chain state unreadable; left pending")
        :skipped
      end
    rescue StandardError => e
      # Backend discipline §1: no write path lets an exception escape unlogged.
      err = ErrorLog.capture!(e)
      err.target = contest
      err.target_name = contest&.slug
      err.save!
      Rails.logger.error("[contest_reconciler][error] #{contest&.slug} #{e.class}: #{e.message}")
      :error
    end

    private

    def derived_pda(contest)
      Solana::Keypair.encode_base58(@vault.contest_pda(contest.slug).first)
    end

    # THREE-VALUED on purpose: :present / :absent / :unknown. One brief retry
    # first — mainnet RPC rate-limits on bursts, and a single transient error
    # should not cost a sweep cycle. An error that survives the retry returns
    # :unknown, NOT :absent, because the absent branch deletes rows.
    def pda_state(pda_b58)
      attempts = 0
      begin
        attempts += 1
        info = @vault.client.get_account_info(pda_b58)
        info && info["value"] ? :present : :absent
      rescue StandardError => e
        if attempts < 2
          sleep(0.25)
          retry
        end
        Rails.logger.warn("[contest_reconciler][rpc] get_account_info failed pda=#{pda_b58} #{e.message}")
        :unknown
      end
    end

    # The contest exists on chain, so the creator's prize pool moved with it.
    # Publish the row. The pool figure is EVIDENCE FOR THE OPERATOR, not a gate
    # — see the header on why a zero pool is legal — so a read that fails must
    # not block the promote.
    def promote!(contest, pda_b58)
      contest.update!(status: :open)
      Rails.logger.info(
        "[contest_reconciler][promoted] #{contest.slug} pda=#{pda_b58} " \
        "prize_pool=#{onchain_prize_pool_dollars(contest) || 'unread'} " \
        "tx=#{contest.onchain_tx_signature.to_s.first(8)}…"
      )
      :promoted
    end

    def onchain_prize_pool_dollars(contest)
      @vault.read_contest(contest.slug)&.dig(:prize_pool_dollars)
    rescue StandardError => e
      Rails.logger.warn("[contest_reconciler][rpc] read_contest failed slug=#{contest.slug} #{e.message}")
      nil
    end

    # No PDA. Delete the squatting row — unless something about it says a human
    # should look first.
    def delete_or_flag!(contest, pda_b58)
      if contest.onchain_tx_signature.present?
        return flag!(contest, "no Contest PDA at #{pda_b58}, but the row carries broadcast signature " \
                              "#{contest.onchain_tx_signature} — READ the chain before removing anything")
      end

      # EVERY table that references contests, not only the two that cascade.
      # `entries` and `messages` are `dependent: :destroy`, so a delete here
      # takes real rows with it. `landing_pages.contest_id` is
      # `on_delete: :nullify`, which is quieter and therefore worse for an
      # AUTOMATIC delete: the landing page survives, silently pointing at
      # nothing, and an admin can attach one to a pending contest today because
      # Admin::LandingPagesController#load_contests lists every contest
      # regardless of status. (`season_configs.main_contest_id` also nullifies
      # and is deliberately NOT checked here: the admin dropdown that feeds it
      # offers open contests only — Admin::DashboardController#show — so a
      # pending contest can reach it only through a hand-forged POST, since
      # SeasonConfig.set_main_contest! itself validates nothing. If that ever
      # happened the FK would clear the pointer, which is visible and
      # recoverable.)
      #
      # A pending strand should have none of these. Having one is a mark of
      # human intent on a row this sweeper was about to remove, so it stops and
      # asks rather than deciding.
      if (referencing = dependent_row_summary(contest)).present?
        return flag!(contest, "no Contest PDA at #{pda_b58}, but the row is referenced by #{referencing} — " \
                              "a delete would destroy or orphan them")
      end

      slug = contest.slug
      contest.destroy!
      Rails.logger.info(
        "[contest_reconciler][deleted] #{slug} pda=#{pda_b58} absent on chain — " \
        "no broadcast landed, slug released"
      )
      :deleted
    end

    # Names what would be destroyed or orphaned, so the alert says which of the
    # three it is rather than making an operator go looking.
    def dependent_row_summary(contest)
      counts = {
        "entries"       => contest.entries.count,
        "messages"      => contest.messages.count,
        "landing pages" => LandingPage.where(contest_id: contest.id).count
      }
      counts.select { |_, n| n.positive? }.map { |label, n| "#{n} #{label}" }.join(", ").presence
    end

    # Stamp the row so the next sweep passes it by, THEN page a human. Order
    # matters: the stamp is what stops an unresolvable row re-alerting every 15
    # minutes until the alert that matters is invisible. Never promotes, never
    # deletes.
    def flag!(contest, reason)
      contest.update!(onchain_reconcile_flagged_at: Time.current)
      err = StrandedContestError.new(
        "Stranded pending contest #{contest.slug} (id=#{contest.id}, creator user_id=#{contest.user_id}) " \
        "needs review: #{reason}. Resolve by hand — this sweeper will not touch it again."
      )
      alert = ErrorLog.capture!(err)
      alert.target = contest
      alert.target_name = contest.slug
      alert.save!
      Rails.logger.warn("[contest_reconciler][needs_review] #{contest.slug} reason=#{reason}")
      :flagged
    end
  end
end
