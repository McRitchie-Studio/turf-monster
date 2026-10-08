require "test_helper"
require Rails.root.join("db/migrate/20261008210000_add_settlement_pending_to_contests")

# [integration] The settlement migration's backfill: a graded on-chain contest
# whose settle transaction is still in flight becomes settlement_pending, and
# nothing else moves.
class AddSettlementPendingBackfillTest < ActiveSupport::TestCase
  setup do
    @migration = AddSettlementPendingToContests.new
    @migration.verbose = false
  end

  def graded(onchain: true, onchain_settled: false)
    contest = Contest.create!(name: "Backfill #{SecureRandom.hex(3)}", slate: slates(:one), rank: 9000 + rand(900),
                              contest_type: "standard", starts_at: 1.hour.ago, user: users(:alex), status: "open",
                              max_entries: 29)
    contest.update_columns(status: "settled", onchain_settled: onchain_settled,
                           onchain_contest_id: (EnteredOnchain.random_wallet if onchain))
    contest
  end

  def settle_row(contest, status:, stale: false, tx_type: "settle_contest")
    PendingTransaction.create!(tx_type: tx_type, serialized_tx: "stx", status: status, target: contest, stale: stale,
                               tx_signature: (status == "pending" ? nil : "sig-#{SecureRandom.hex(6)}"))
  end

  test "a graded contest with a settle awaiting a cosign or a chain verdict becomes settlement_pending" do
    awaiting_cosign = graded.tap { |c| settle_row(c, status: "pending") }
    awaiting_verdict = graded.tap { |c| settle_row(c, status: "submitted") }

    @migration.backfill_settlements_in_flight

    assert_equal %w[settlement_pending settlement_pending],
                 [awaiting_cosign, awaiting_verdict].map { |c| c.reload.status }
    assert_nothing_raised { @migration.backfill_settlements_in_flight }
  end

  test "control: settled contests with no settle in flight keep reading settled" do
    paid = graded(onchain_settled: true).tap { |c| settle_row(c, status: "pending") }
    confirmed = graded.tap { |c| settle_row(c, status: "confirmed") }
    judged_dead = graded.tap { |c| settle_row(c, status: "pending", stale: true) }
    off_chain = graded(onchain: false).tap { |c| settle_row(c, status: "pending") }
    other_row = graded.tap { |c| settle_row(c, status: "pending", tx_type: "cancel_contest") }
    no_row = graded

    @migration.backfill_settlements_in_flight

    assert_equal ["settled"], [paid, confirmed, judged_dead, off_chain, other_row, no_row].map { |c| c.reload.status }.uniq
  end
end
