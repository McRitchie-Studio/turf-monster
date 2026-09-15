# EVERY vault signer that signed, not just the last one to be asked.
#
# `cosigner_address` is a single string, and it was enough while an operator
# cosign meant exactly two signatures: the server's admin key, and one Phantom
# wallet. Under turf-vault v0.26 six of these actions need THREE, so a
# confirmed transaction now carries two Phantom signatures and the singular
# column can only ever name one of them.
#
# ADDITIVE, AND THE OLD COLUMN KEEPS ITS MEANING. `cosigner_address` goes on
# holding the FIRST (named) cosigner — the slot the builder has always
# reserved — so every existing reader, view and test keeps working unchanged
# and no backfill is needed. The new column holds the full ordered set,
# including that first one, because the thing an audit asks later is "who
# authorised this payout", and an answer assembled by unioning one column with
# another is an answer that can be assembled wrong.
#
# ORDERED, because the order is not cosmetic: turf-vault's `authorize` reads
# the leading `remaining_accounts` POSITIONALLY, so signer N's signature must
# land in slot N. Storing the order is what lets a failed transaction be
# re-examined against the slots it actually reserved.
#
# Defaults to `[]` rather than NULL so a reader never has to tell "no signers
# recorded" apart from "this row predates the column" — both are empty, and
# `cosigner_address` is where a pre-v0.26 row's signer still is.
class AddCosignerAddressesToPendingTransactions < ActiveRecord::Migration[8.1]
  def change
    add_column :pending_transactions, :cosigner_addresses, :jsonb, default: [], null: false
  end
end
