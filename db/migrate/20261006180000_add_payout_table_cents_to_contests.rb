# The prize per rank a contest pays, in cents, written once when the contest is
# created (Contest#snapshot_payout_table). Grading reads it, so a later edit to
# Contest::FORMATS never settles a contest against a pool funded at other
# numbers. Existing rows fill from Contests::PayoutTableBackfillJob after the
# deploy; until then Contest#payouts reads Contest::PRE_SNAPSHOT_PAYOUTS for them.
class AddPayoutTableCentsToContests < ActiveRecord::Migration[8.1]
  def change
    add_column :contests, :payout_table_cents, :bigint, array: true
  end
end
