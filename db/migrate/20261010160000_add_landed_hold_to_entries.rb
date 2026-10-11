# The landed-entry hold (Entry::LandedHold): when a paid entry an app gate
# refused landed, the player's answer to the re-authorize prompt, and the
# operator's replacement.
#
# Safe on a live table: nullable columns only (no rewrite, no backfill), and
# the answer's check constraint is added NOT VALID and validated in its own
# statement, so the add takes no long lock. Rows that landed before this
# column read their hold from payment_submitted_at instead.
class AddLandedHoldToEntries < ActiveRecord::Migration[8.1]
  disable_ddl_transaction!

  ANSWER_CHECK = "entries_landed_answer_known".freeze

  def up
    add_column :entries, :payment_landed_at, :datetime, if_not_exists: true
    add_column :entries, :landed_answer, :string, if_not_exists: true
    add_column :entries, :landed_answered_at, :datetime, if_not_exists: true
    add_column :entries, :landed_replaced_at, :datetime, if_not_exists: true
    add_column :entries, :landed_replaced_by_id, :bigint, if_not_exists: true

    unless check_constraint_exists?(:entries, name: ANSWER_CHECK)
      add_check_constraint :entries, "landed_answer IS NULL OR landed_answer IN ('reauthorized', 'declined')",
                           name: ANSWER_CHECK, validate: false
    end
    validate_check_constraint :entries, name: ANSWER_CHECK
  end

  def down
    remove_check_constraint :entries, name: ANSWER_CHECK, if_exists: true
    %i[payment_landed_at landed_answer landed_answered_at landed_replaced_at landed_replaced_by_id].each do |column|
      remove_column :entries, column, if_exists: true
    end
  end
end
