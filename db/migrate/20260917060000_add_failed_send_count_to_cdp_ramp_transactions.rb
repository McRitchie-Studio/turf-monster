# THE COUNTER BEHIND THE FAILED-SEND CAP (cap-cashout-failed-send-rearms).
#
# A Phantom cash-out wire names the house as fee payer, and a wire that
# executes and FAILS still charges it. Cdp::OfframpSendsController#cosign used
# to re-arm a row on every :failed verdict with no count, so a player whose
# wire passes the simulation and fails on landing could make the house pay for
# failure after failure for the whole send window.
# CdpRampTransaction#rearm_after_failed_send! counts each one here and ends the
# row at CdpRampTransaction::MAX_FAILED_SENDS.
#
# A column, not a key in raw_payload: Cdp::RampPollJob overwrites raw_payload
# with Coinbase's latest status body on every poll, which would reset the count.
#
# A constant default with NOT NULL is a metadata-only change on PostgreSQL 11+:
# no table rewrite, and existing rows read 0.
class AddFailedSendCountToCdpRampTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :cdp_ramp_transactions, :failed_send_count, :integer, default: 0, null: false
  end
end
