module Contests
  # The settlement half of the chain sweep (entries: Entries::PaymentSweepJob).
  # Every settle_contest transaction left `submitted` is settled from the
  # chain by Contests::SettlementReconciler: a confirmed signature settles its
  # contest; one that failed or can no longer land returns to the cosign queue
  # with the reason on the contest, and only when the contest account reads
  # Open or Locked at `finalized`; an unreadable chain leaves the row for the
  # next run. It only reads the chain, so a retried run sends nothing.
  #
  # NO ROW IS MOVED BY ITS AGE. The age of a broadcast only separates "not
  # seen yet" from "can never land" for a signature the chain has no record of
  # (OnchainSendVerdict#send_verdict).
  #
  # EVERY UNPAID GRADED CONTEST IS NAMED, EVERY RUN. The log line carries the
  # slugs still settlement_pending and the rows only a person can move: a
  # claimed row with no signature, or one with no broadcast time, has nothing
  # the sweep can ask the chain about.
  class SettlementSweepJob < ApplicationJob
    queue_as :default
    self.rpc_long_budget = :reconcile_sweep

    # The request that broadcast the row gets this long to record it first.
    SETTLE_AFTER = 45.seconds
    BATCH = 50

    def perform
      stats = Hash.new(0)
      stats[:healed] = heal_confirmed
      rows = submitted.to_a
      vault = Solana::Vault.new if rows.any?
      rows.each do |tx|
        stats[Contests::SettlementReconciler.call(tx, vault: vault).status] += 1
      rescue StandardError => e
        stats[:error] += 1
        ErrorLog.capture!(e)
      end

      pending = Contest.settlement_pending.order(:id).limit(BATCH).pluck(:slug)
      stuck = needs_a_person.limit(BATCH).pluck(:slug)
      Rails.logger.info("[settlement][sweep] #{stats.to_h} pending=#{pending.size} slugs=#{pending.join(',')} " \
                        "needs_person=#{stuck.size} rows=#{stuck.join(',')}")
      stats
    end

    private

    def settle_rows
      PendingTransaction.where(tx_type: Contest::Settlement::SETTLE_TX_TYPE, target_type: "Contest")
    end

    def submitted
      settle_rows.submitted.where.not(tx_signature: [nil, ""])
                 .where("broadcast_at IS NULL OR broadcast_at <= ?", SETTLE_AFTER.ago)
                 .order(Arel.sql("broadcast_at NULLS FIRST"), :id).limit(BATCH)
    end

    # A settle already verified and confirmed whose contest write did not
    # finish. The row holds the proof, so no chain read is needed.
    def heal_confirmed
      rows = settle_rows.confirmed.where.not(tx_signature: [nil, ""])
                        .where(target_id: Contest.settlement_pending.select(:id)).limit(BATCH)
      rows.count do |tx|
        tx.target.mark_settled!(tx.tx_signature)
      rescue StandardError => e
        ErrorLog.capture!(e)
        false
      end
    end

    def needs_a_person
      settle_rows.submitted.where("tx_signature IS NULL OR tx_signature = '' OR broadcast_at IS NULL").order(:id)
    end
  end
end
