module Entries
  # The player who never came back. Every entry left `submitted` is settled from
  # the chain: a ticket that exists confirms the entry; an attempt that can no
  # longer land (the wire's last valid block height, not a clock) returns the
  # cart to draft with its picks; a chain that cannot be read leaves the row
  # for the next run. It only reads the chain, so a retried run sends nothing.
  #
  # `landed` rows are not swept: they are paid entries an app gate refused, and
  # they wait for a person (Entry::Payment).
  class PaymentSweepJob < ApplicationJob
    queue_as :default
    self.rpc_long_budget = :reconcile_sweep

    # A request still holding the row gets this long before the sweep looks.
    SETTLE_AFTER = 45.seconds
    BATCH = 200

    def perform
      healed = Entry.where(payment_state: Entry::Payment::IN_FLIGHT, status: %w[active complete])
                    .update_all(payment_state: "confirmed")
      stats = Hash.new(0)
      stale.find_each do |entry|
        stats[Entries::PaymentSettlement.call(entry).status] += 1
      rescue StandardError => e
        stats[:error] += 1
        ErrorLog.capture!(e)
      end
      Rails.logger.info("[entry-payment][sweep] healed=#{healed} #{stats.to_h}")
      stats
    end

    private

    def stale
      Entry.where(payment_state: "submitted", status: "cart")
           .where(payment_submitted_at: ..SETTLE_AFTER.ago)
           .order(:payment_submitted_at).limit(BATCH)
    end
  end
end
