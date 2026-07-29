# Reconcile stranded `pending` TransactionLog DEPOSIT rows against the chain.
#
# StripeDepositJob (OPSEC-022 / money-path) CLAIMS a `pending` TransactionLog
# row BEFORE the irreversible `vault.fund_user` transfer, captures the returned
# signature DURABLY the instant fund_user returns, then flips the row to
# `completed`. A process death — or a completion-write fault — AFTER the claim
# strands a `pending` row. That row is SAFE (a retry loses the claim race on the
# unique index and returns without ever re-transferring) but AMBIGUOUS: the
# on-chain transfer may or may not have actually landed.
#
# This service RESOLVES that ambiguity with an ON-CHAIN CHECK — never a blind
# status flip:
#
#   * The row carries a signature that CONFIRMED on-chain (err:nil, confirmed
#     or finalized) → finalize it to `completed`.
#   * The signature FAILED on-chain (meta.err present) or is NOT FOUND after
#     searching history → flag `needs_review` + alert (ErrorLog → Sentry).
#   * The row carries NO signature → landing cannot be proven → flag
#     `needs_review` + alert. (Almost always "died before/at transfer, no money
#     moved"; the rare "transfer landed but the sig-capture write itself
#     faulted" also lands here — safe, because a human resolves it.)
#
# GUARDRAIL — READ-ONLY. This service NEVER calls fund_user, any transfer, any
# mint, or any signing/keypair code. The entire point is to avoid double-paying,
# so it only READS the chain to confirm what already (or never) happened. The
# only writes it makes are to the Rails TransactionLog row (completed /
# needs_review) and the alert ErrorLog.
#
# Mirrors the Entries::OnchainReconciler pattern (service + thin job); scheduled
# recurring via PendingDepositReconcilerJob (config/schedule.yml, sidekiq-cron).
module Deposits
  class OnchainReconciler
    # Synthetic error carried into ErrorLog.capture! so a stranded deposit pages
    # a human the same way a caught exception would (DB row + Sentry).
    class StrandedDepositError < StandardError; end

    # Rows younger than this are still plausibly in-flight (a slow sign/confirm,
    # an ApplicationJob retry backoff), so we never touch them.
    RECONCILE_AFTER = 10.minutes

    # getSignatureStatuses confirmationStatus values that mean "the transfer
    # durably landed" — enough to finalize a money row.
    LANDED_STATUSES = %w[confirmed finalized].freeze

    def self.run(older_than: RECONCILE_AFTER, vault: Solana::Vault.new)
      new(vault: vault).run(older_than: older_than)
    end

    def initialize(vault: Solana::Vault.new)
      @vault = vault
    end

    # Sweep every aged, stranded pending deposit. Returns a counts hash
    # ({ reconciled:, flagged:, skipped:, error: }).
    def run(older_than: RECONCILE_AFTER)
      cutoff = older_than.ago
      scope = TransactionLog.pending
                            .by_type("deposit")
                            .where("transaction_logs.created_at < ?", cutoff)
      stats = Hash.new(0)
      scope.find_each { |log| stats[reconcile(log)] += 1 }
      Rails.logger.info(
        "[deposit_reconciler] checked=#{stats.values.sum} reconciled=#{stats[:reconciled]} " \
        "flagged=#{stats[:flagged]} skipped=#{stats[:skipped]} errors=#{stats[:error]} " \
        "cutoff=#{cutoff.iso8601}"
      )
      stats
    end

    # Reconcile one row. Returns :reconciled / :flagged / :skipped / :error.
    def reconcile(log)
      return :skipped unless log.status == "pending" && log.transaction_type == "deposit"

      sig = log.onchain_tx.presence
      return flag!(log, "no on-chain signature recorded — transfer likely never broadcast") if sig.nil?

      case onchain_outcome(sig)
      when :landed
        log.update!(status: "completed")
        Rails.logger.info("[deposit_reconciler][reconciled] #{log.slug} tx=#{sig.to_s.first(8)}…")
        :reconciled
      when :failed
        flag!(log, "on-chain transfer FAILED (tx #{sig.to_s.first(8)}… returned an error)")
      when :not_found
        flag!(log, "signature #{sig.to_s.first(8)}… not found on-chain after threshold")
      else # :inconclusive — a still-confirming status; leave it for the next sweep.
        Rails.logger.info("[deposit_reconciler][skip] #{log.slug} inconclusive on-chain status; left pending")
        :skipped
      end
    rescue StandardError => e
      # Discipline §1: no backend write path lets an exception escape unlogged.
      err = ErrorLog.capture!(e)
      err.target = log
      err.target_name = log&.slug
      err.save!
      Rails.logger.error("[deposit_reconciler][error] #{log&.slug} #{e.class}: #{e.message}")
      :error
    end

    private

    # READ-ONLY on-chain landing check. getSignatureStatuses with
    # searchTransactionHistory:true (via the vault's RPC client) — the same
    # envelope ContestsController#recover_pending_entry consumes:
    #   { "value" => [ { "err" =>, "confirmationStatus" => } | nil ] }
    # No transfer, no signing — a pure read.
    def onchain_outcome(signature)
      status = @vault.client.confirm_transaction(signature)&.dig("value", 0)
      return :not_found if status.nil?
      return :failed if status["err"]

      LANDED_STATUSES.include?(status["confirmationStatus"]) ? :landed : :inconclusive
    end

    # Move the row to the distinct terminal state FIRST (out of `pending` scope,
    # so a later sweep never re-alerts the same row), THEN page a human. Never
    # completes, never re-transfers.
    def flag!(log, reason)
      log.update!(status: "needs_review")
      err = StrandedDepositError.new(
        "Stranded Stripe deposit #{log.slug} (user_id=#{log.user_id}, " \
        "$#{format('%.2f', log.amount_dollars)}) needs review: #{reason}. " \
        "READ the chain and resolve manually — do NOT blindly re-transfer."
      )
      alert = ErrorLog.capture!(err)
      alert.target = log
      alert.target_name = log.slug
      alert.parent = log.user
      alert.parent_name = log.user&.try(:slug)
      alert.save!
      Rails.logger.warn("[deposit_reconciler][needs_review] #{log.slug} reason=#{reason}")
      :flagged
    end
  end
end
