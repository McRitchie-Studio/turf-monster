# The entry's payment state machine (Entry::Payment).
#
# Safe on a live table: each column is added with a constant default (no
# rewrite), the backfill runs in batches outside a transaction, and the unique
# index is built concurrently. Rows an old dyno activates during the deploy keep
# `draft` beside status `active`; Entry::Payment reads status first, so they
# are harmless and need no second backfill.
class AddPaymentStateToEntries < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  class MigrationEntry < ActiveRecord::Base
    self.table_name = "entries"
  end

  IN_FLIGHT_INDEX = "index_entries_one_payment_in_flight".freeze

  def up
    add_column :entries, :payment_state, :string, null: false, default: "draft", if_not_exists: true
    add_column :entries, :payment_rail, :string, if_not_exists: true
    add_column :entries, :payment_signature, :string, if_not_exists: true
    add_column :entries, :payment_submitted_at, :datetime, if_not_exists: true
    add_column :entries, :payment_last_valid_block_height, :bigint, if_not_exists: true
    add_column :entries, :payment_refusal_code, :string, if_not_exists: true

    MigrationEntry.where(status: %w[active complete]).where.not(payment_state: "confirmed")
                  .in_batches(of: 1_000) { |batch| batch.update_all(payment_state: "confirmed") }

    # A cart whose Phantom wire was stamped and sent, verdict not in: the newest
    # one per player and contest, so the index below can always be built.
    execute <<~SQL.squish
      UPDATE entries e
      SET payment_state = 'submitted', payment_rail = 'phantom', payment_signature = p.tx_signature,
          payment_submitted_at = p.sent_at, wallet_address = COALESCE(e.wallet_address, p.initiator_address)
      FROM (
        SELECT DISTINCT ON (e2.user_id, e2.contest_id)
               p2.target_id, p2.tx_signature, p2.initiator_address,
               COALESCE(p2.broadcast_at, p2.updated_at) AS sent_at
        FROM pending_transactions p2
        JOIN entries e2 ON e2.id = p2.target_id
        WHERE p2.target_type = 'Entry' AND p2.tx_type = 'enter_contest' AND p2.status = 'submitted'
          AND p2.tx_signature IS NOT NULL AND p2.tx_signature <> ''
          AND e2.status = 'cart' AND e2.entry_number IS NOT NULL AND e2.payment_state = 'draft'
        ORDER BY e2.user_id, e2.contest_id, p2.created_at DESC
      ) p
      WHERE e.id = p.target_id
    SQL

    add_index :entries, %i[user_id contest_id], unique: true, name: IN_FLIGHT_INDEX,
              where: "payment_state IN ('submitted', 'landed')", algorithm: :concurrently, if_not_exists: true
  end

  def down
    remove_index :entries, name: IN_FLIGHT_INDEX, algorithm: :concurrently, if_exists: true
    %i[payment_state payment_rail payment_signature payment_submitted_at
       payment_last_valid_block_height payment_refusal_code].each do |column|
      remove_column :entries, column, if_exists: true
    end
  end
end
