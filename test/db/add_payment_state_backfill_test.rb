require "test_helper"
require Rails.root.join("db/migrate/20261008190000_add_payment_state_to_entries")

# [integration] The payment-state migration's backfill of carts whose Phantom
# wire was already stamped: one row per player and contest, the wire's height
# carried over, and safe to run twice.
class AddPaymentStateBackfillTest < ActiveSupport::TestCase
  setup do
    @contest = contests(:one)
    @user = users(:sam)
    @migration = AddPaymentStateToEntries.new
    @migration.verbose = false
  end

  def stamped_cart(slot:, signature:, created_at:, metadata: { last_valid_block_height: 4_321 }.to_json)
    entry = @contest.entries.create!(user: @user, status: :cart, entry_number: slot)
    PendingTransaction.create!(tx_type: "enter_contest", serialized_tx: "stx", status: "submitted", target: entry,
                               tx_signature: signature, broadcast_at: created_at, created_at: created_at,
                               initiator_address: "StampedWallet", metadata: metadata)
    entry
  end

  def in_flight = @contest.entries.where(user: @user, payment_state: "submitted")

  test "the newest stamped cart is marked, with its wallet, stamp time and the wire's height" do
    older = stamped_cart(slot: 0, signature: "sig-old", created_at: 2.hours.ago)
    newest = stamped_cart(slot: 1, signature: "sig-new", created_at: 1.hour.ago)

    @migration.backfill_stamped_carts

    assert_equal [newest.id], in_flight.pluck(:id)
    newest.reload
    assert_equal ["phantom", "sig-new", "StampedWallet", 4_321],
                 newest.values_at(:payment_rail, :payment_signature, :wallet_address, :payment_last_valid_block_height)
    assert_in_delta 1.hour.ago, newest.payment_submitted_at, 5.seconds
    assert_equal "draft", older.reload.payment_state
  end

  test "running it again marks no second cart, so the unique index still holds" do
    stamped_cart(slot: 0, signature: "sig-old", created_at: 2.hours.ago)
    newest = stamped_cart(slot: 1, signature: "sig-new", created_at: 1.hour.ago)

    @migration.backfill_stamped_carts
    assert_nothing_raised { @migration.backfill_stamped_carts }

    assert_equal [newest.id], in_flight.pluck(:id)
  end

  test "CONTROL: a cart with no stamped wire, and one whose wire carries no height, are left as they should be" do
    plain = @contest.entries.create!(user: @user, status: :cart, entry_number: 0)
    other = stamped_cart(slot: 1, signature: "sig-bare", created_at: 1.hour.ago, metadata: { entry_pda: "x" }.to_json)

    @migration.backfill_stamped_carts

    assert_equal "draft", plain.reload.payment_state
    assert_equal ["submitted", nil], other.reload.values_at(:payment_state, :payment_last_valid_block_height)
    refute other.payment_release_allowed?(status: nil, finalized_block_height: 9_999_999, now: 1.year.from_now),
           "with no height it is never released by a clock"
  end
end
