module Entries
  # Out-of-band self-heal for a stranded on-chain-paid entry. Enqueued by
  # ContestsController#enter when a post-broadcast Entry#confirm! fails (the
  # token/USDC is already spent on-chain, so the entry must converge to active
  # rather than sit in `cart`). Idempotent — see Entries::OnchainReconciler;
  # re-running never double-enters or double-charges.
  #
  # Given an entry_id, heals that one entry. With no id, sweeps every eligible
  # open contest (the scheduled / operator path, mirroring the rake task).
  class OnchainReconcileJob < ApplicationJob
    queue_as :default
    self.rpc_long_budget = :reconcile_sweep

    def perform(entry_id = nil)
      # OnchainReconciler.reconcile_entry rescues + logs its OWN per-entry faults
      # and returns :error, so this wrapper exists for job-level faults: a
      # find_by / sweep-enumeration error that would otherwise escape to Sidekiq
      # unlogged. Capture with whatever context we have, then RE-RAISE so Sidekiq
      # still retries the job.
      entry = Entry.find_by(id: entry_id) if entry_id

      if entry_id
        return Rails.logger.info("[reconcile][job] entry_id=#{entry_id} gone — nothing to do") unless entry
        outcome = Entries::OnchainReconciler.reconcile_entry(entry)
        Rails.logger.info("[reconcile][job] entry_id=#{entry_id} -> #{outcome}")
      else
        stats = Entries::OnchainReconciler.run
        Rails.logger.info("[reconcile][job] sweep -> #{stats.to_h}")
      end
    rescue StandardError => e
      error_log = ErrorLog.capture!(e)
      if entry
        error_log.target = entry
        error_log.target_name = entry.slug
        if entry.contest
          error_log.parent = entry.contest
          error_log.parent_name = entry.contest.slug
        end
      end
      error_log.save!
      Rails.logger.error("[reconcile][job][error] entry_id=#{entry_id} #{e.class}: #{e.message}")
      raise e
    end
  end
end
