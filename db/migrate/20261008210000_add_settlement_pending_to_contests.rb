# The contest's settlement lifecycle (Contest::Settlement).
#
# `contests.status` gains the value `settlement_pending` (a string column, so
# no DDL) and `contests.settlement_error` carries the reason the last settle
# attempt did not pay. `transaction_logs.amount_cents` becomes nullable so a
# payout row can be a pointer to the settle signature with no amount.
#
# Safe on a live table: one nullable column with no default, one constraint
# dropped, and a backfill that touches only contests with a settlement in
# flight. A dyno still running the previous release reads `settlement_pending`
# as an unknown status for the length of the deploy; it writes nothing to it.
class AddSettlementPendingToContests < ActiveRecord::Migration[8.1]
  # A graded on-chain contest whose settle transaction is still waiting on a
  # cosign or a chain verdict is not settled. Rows marked stale are left alone:
  # an operator has already judged them dead.
  IN_FLIGHT = <<~SQL.squish.freeze
    status = 'settled'
    AND onchain_settled = FALSE
    AND onchain_contest_id IS NOT NULL AND onchain_contest_id <> ''
    AND EXISTS (
      SELECT 1 FROM pending_transactions
      WHERE pending_transactions.target_type = 'Contest'
        AND pending_transactions.target_id = contests.id
        AND pending_transactions.tx_type = 'settle_contest'
        AND pending_transactions.status IN ('pending', 'submitted')
        AND pending_transactions.stale = FALSE
    )
  SQL

  def up
    add_column :contests, :settlement_error, :text, if_not_exists: true
    change_column_null :transaction_logs, :amount_cents, true

    execute("UPDATE contests SET status = 'settlement_pending' WHERE #{IN_FLIGHT}")
  end

  # Returns every pending settlement to the previous reading (settled at
  # grade). `amount_cents` stays nullable: pointer rows written since `up`
  # carry no amount, and restoring NOT NULL would refuse them.
  def down
    execute("UPDATE contests SET status = 'settled' WHERE status = 'settlement_pending'")
    remove_column :contests, :settlement_error, if_exists: true
  end
end
