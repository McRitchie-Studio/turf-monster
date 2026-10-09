module Entries
  # The player who never came back. Every entry left `submitted` is settled from
  # the chain: a ticket that exists confirms the entry; an attempt that can no
  # longer land (the wire's last valid block height, not a clock) returns the
  # cart to draft with its picks; a chain that cannot be read leaves the row
  # for the next run. It only reads the chain, so a retried run sends nothing.
  #
  # `landed` rows are not swept: they are paid entries an app gate refused, and
  # they wait for a person (Entry::Payment).
  #
  # A ROW CLEARED UNDER A PAYMENT IS READ TOO. An abandoned row that still holds
  # the in-flight key is a cart whose clear raced its payment: it is restored
  # (Entry::Payment#restore_cleared_payment!) and settled like any other.
  #
  # ROWS NO CLOCK WILL EVER RELEASE ARE NAMED, EVERY RUN. A signed row with no
  # recorded block height or no stamp time (backfilled or adopted from before
  # this machine) is still settled if its payment turns up, but it can only be
  # released by a person. The log line carries their count and their slugs
  # (`never_by_clock=`), so they are never invisible.
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
      unrestored = restore_cleared
      stale.find_each do |entry|
        stats[Entries::PaymentSettlement.call(entry).status] += 1
      rescue StandardError => e
        stats[:error] += 1
        ErrorLog.capture!(e)
      end
      waiting = Entry.payment_never_released_by_clock.order(:id).limit(BATCH).pluck(:slug)
      stats[:never_by_clock] = waiting.size if waiting.any?
      stats[:cleared_unrestored] = unrestored.size if unrestored.any?
      Rails.logger.info("[entry-payment][sweep] healed=#{healed} #{stats.to_h} never_by_clock=#{waiting.size} slugs=#{waiting.join(',')} " \
                        "cleared_unrestored=#{unrestored.size} cleared_slugs=#{unrestored.join(',')}")
      stats
    end

    private

    # A row cleared under a payment (abandoned, still holding the in-flight
    # key) is made a cart again, so `stale` reads it in this same run. Answers
    # the slugs of the ones whose slot could not be recovered: they are left
    # for a person and named in the log every run.
    def restore_cleared
      cleared = Entry.where(status: "abandoned", payment_state: Entry::Payment::IN_FLIGHT).order(:id).limit(BATCH)
      cleared.reject do |entry|
        entry.restore_cleared_payment!
      rescue StandardError => e
        ErrorLog.capture!(e)
        false
      end.map(&:slug)
    end

    def stale
      Entry.where(payment_state: "submitted", status: "cart")
           .where("payment_submitted_at IS NULL OR payment_submitted_at <= ?", SETTLE_AFTER.ago)
           .order(Arel.sql("payment_submitted_at NULLS FIRST")).limit(BATCH)
    end
  end
end
