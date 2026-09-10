# A pending transaction nobody will ever cosign should not keep asking to be
# cosigned. Production carried 11 `pending` rows on 2026-09-07, of which 10 were
# `enter_contest` transactions from June and July whose flows had long since
# moved on — so a badge counting `pending` would have read 11 on the day it
# shipped, with exactly one thing actually waiting.
#
# Deliberately a flag and not a deletion: these rows are the audit trail for
# entries that really were attempted, and the treasury page still lists them.
# `stale` only says "stop counting this", never "this did not happen".
class AddStaleToPendingTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :pending_transactions, :stale, :boolean, default: false, null: false

    # The badge's exact query — every page load for an admin runs it.
    add_index :pending_transactions, [:status, :stale]
  end
end
