module Entries
  # Finishes one entry's payment after the request that sent it had to answer
  # (Entries::ManagedEntry::PendingConfirmation). It only READS the chain and
  # moves the row, so a retry of this job can never send anything.
  class PaymentSettleJob < ApplicationJob
    queue_as :default
    self.rpc_long_budget = :reconcile_sweep

    RECHECK = 10.seconds
    # Past a blockhash's life and its finality; Entries::PaymentSweepJob has
    # anything still unreadable after that.
    MAX_CHECKS = 18

    def perform(entry_id, checks = 0)
      entry = Entry.find_by(id: entry_id)
      return unless entry&.payment_in_flight?

      settled = Entries::PaymentSettlement.call(entry)
      Rails.logger.info("[entry-payment][job] entry=#{entry_id} check=#{checks} -> #{settled.status}")
      self.class.set(wait: RECHECK).perform_later(entry_id, checks + 1) if settled.pending? && checks < MAX_CHECKS
    end
  end
end
