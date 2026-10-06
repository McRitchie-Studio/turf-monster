module Contests
  # Writes the payout table onto every contest created before payout snapshots
  # existed: Contest::PRE_SNAPSHOT_PAYOUTS for the row's format, the table those
  # contests were funded and opened with. Rows that already carry a table are
  # never touched, so a re-run changes nothing, and rows of a format with no
  # pre-snapshot table (retired formats) keep reading their own entries.
  #
  # Runs once as the release's post-deploy command:
  #   bin/rails runner "Contests::PayoutTableBackfillJob.perform_now"
  # It prints what it wrote and raises if any row it should fill is still empty
  # afterwards, so a failed backfill fails the post-deploy step.
  class PayoutTableBackfillJob < ApplicationJob
    queue_as :default

    def perform
      written = Contest::PRE_SNAPSHOT_PAYOUTS.sum do |format, cents|
        # update_all, because the column is attr_readonly on the model: this is
        # the one write that fills it after creation, and only where it is empty.
        Contest.where(contest_type: format, payout_table_cents: nil).update_all(payout_table_cents: cents)
      end

      missing = Contest.where(contest_type: Contest::PRE_SNAPSHOT_PAYOUTS.keys, payout_table_cents: nil).count
      raise "#{missing} contest(s) still have no payout table" if missing.positive?

      untabled = Contest.where(payout_table_cents: nil).count
      message = "[Contests::PayoutTableBackfillJob] wrote #{written} payout table(s); " \
                "#{untabled} contest(s) of a retired format read their entries"
      Rails.logger.info(message)
      puts message
      written
    end
  end
end
