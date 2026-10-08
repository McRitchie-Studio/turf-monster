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

    backfill_stamped_carts

    add_index :entries, %i[user_id contest_id], unique: true, name: IN_FLIGHT_INDEX,
              where: "payment_state IN ('submitted', 'landed')", algorithm: :concurrently, if_not_exists: true
  end

  # A cart whose Phantom wire was stamped and sent, verdict not in, becomes
  # `submitted`: the newest one per player and contest, and ONLY where that
  # player has no row in flight in that contest already. So the index can
  # always be built, and running this again (a re-run of the migration after a
  # failure further down) marks nothing more.
  #
  # The wire's last valid block height is copied from the prepared row, so the
  # sweep can release a row that never landed; without one a signed row is
  # never released by a clock (Entry::Payment#payment_release_allowed?).
  def backfill_stamped_carts
    execute <<~SQL.squish
      UPDATE entries e
      SET payment_state = 'submitted', payment_rail = 'phantom', payment_signature = p.tx_signature,
          payment_submitted_at = p.broadcast_at, wallet_address = COALESCE(e.wallet_address, p.initiator_address)
      FROM (
        SELECT DISTINCT ON (e2.user_id, e2.contest_id)
               p2.target_id, p2.tx_signature, p2.initiator_address, p2.broadcast_at
        FROM pending_transactions p2
        JOIN entries e2 ON e2.id = p2.target_id
        WHERE p2.target_type = 'Entry' AND p2.tx_type = 'enter_contest' AND p2.status = 'submitted'
          AND p2.tx_signature IS NOT NULL AND p2.tx_signature <> ''
          AND e2.status = 'cart' AND e2.entry_number IS NOT NULL AND e2.payment_state = 'draft'
          AND NOT EXISTS (
            SELECT 1 FROM entries held
            WHERE held.user_id = e2.user_id AND held.contest_id = e2.contest_id
              AND held.payment_state IN ('submitted', 'landed')
          )
        ORDER BY e2.user_id, e2.contest_id, p2.created_at DESC
      ) p
      WHERE e.id = p.target_id
    SQL

    MigrationEntry.where(payment_state: "submitted", payment_rail: "phantom", payment_last_valid_block_height: nil)
                  .where.not(payment_signature: nil).find_each do |entry|
      metadata = select_value(<<~SQL.squish)
        SELECT metadata #>> '{}' FROM pending_transactions
        WHERE target_type = 'Entry' AND target_id = #{entry.id.to_i} AND tx_signature = #{quote(entry.payment_signature)}
        ORDER BY id DESC LIMIT 1
      SQL
      height = begin
        parsed = JSON.parse(metadata.to_s)
        parsed.is_a?(Hash) ? parsed["last_valid_block_height"].presence&.to_i : nil
      rescue JSON::ParserError
        nil
      end
      entry.update_columns(payment_last_valid_block_height: height) if height
    end
  end

  def down
    remove_index :entries, name: IN_FLIGHT_INDEX, algorithm: :concurrently, if_exists: true
    %i[payment_state payment_rail payment_signature payment_submitted_at
       payment_last_valid_block_height payment_refusal_code].each do |column|
      remove_column :entries, column, if_exists: true
    end
  end
end
