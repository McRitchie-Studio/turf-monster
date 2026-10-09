require "test_helper"
require "minitest/mock"

# [unit] THE CONTEST'S SETTLEMENT STATE MACHINE (Contest::Settlement).
#
# Grading an on-chain contest writes a proposal and queues the settle
# transaction; the contest reads settlement_pending. It reads settled only when
# #mark_settled! is handed the confirmed signature. A settle that fails or
# expires leaves it settlement_pending with the reason, and its
# PendingTransaction back in the cosign queue. Each rule has a control that
# runs the same contest down the path the rule does not cover.
class ContestSettlementTest < ActiveSupport::TestCase
  SIGNATURE = "SettleSig1111111111111111111111111111111111111111111111111111111".freeze

  setup do
    @contest = Contest.create!(name: "Settlement state #{SecureRandom.hex(3)}", slate: slates(:one),
                               rank: 9000 + rand(900), contest_type: "standard", starts_at: 1.hour.ago,
                               user: users(:alex), status: "open", max_entries: 29)
  end

  # ── grade → settlement_pending ───────────────────────────────────────────

  test "grade_leaves_settlement_pending: an on-chain contest with a winner owed is graded, not settled" do
    make_onchain
    winner = make_entry(score: 100.0)

    grade!

    @contest.reload
    assert_equal "settlement_pending", @contest.status
    refute @contest.settled?, "nothing has confirmed on chain"
    refute @contest.onchain_settled?
    assert @contest.graded?
    assert_equal [1, 300_00], [winner.reload.rank, winner.payout_cents], "the proposal is written"
    assert_equal "pending", @contest.settlement_transaction.status, "the settle is queued for a cosign"
    assert_equal 0, TransactionLog.where(source: @contest).count, "no ledger row before the chain confirms"
  end

  test "control: an off-chain contest owes nothing on chain and settles at grade" do
    make_entry(score: 100.0)

    grade!

    assert_equal "settled", @contest.reload.status
    assert_nil @contest.settlement_transaction
  end

  test "control: an on-chain contest where no entry won a prize settles at grade" do
    make_onchain
    Contest.where(id: @contest.id).update_all(payout_table_cents: [0]) # a table that pays nobody
    @contest.reload
    make_entry(score: 100.0)

    grade!

    assert_equal "settled", @contest.reload.status
    assert @contest.onchain_settled?
    assert_nil @contest.settlement_transaction
  end

  test "grading tells no winner; the winners are told when the settle confirms" do
    make_onchain
    make_entry(score: 100.0)
    notified = []

    Contests::WinnerNotifier.stub(:call, ->(contest) { notified << contest.slug }) do
      grade!
      assert_empty notified, "grade must not announce a payout that has not landed"

      @contest.mark_settled!(SIGNATURE)
    end

    assert_equal [@contest.slug], notified
  end

  test "a second grade of a settlement_pending contest is refused and changes nothing" do
    make_onchain
    winner = make_entry(score: 100.0)
    grade!
    winner.update_columns(score: 1.0)

    error = assert_raises(RuntimeError) { grade! }

    assert_equal Contest::Settlement::SETTLEMENT_PENDING_GRADE_MESSAGE, error.message
    assert_equal 300_00, winner.reload.payout_cents, "the proposal is fixed at the first grade"
    assert_equal 1, PendingTransaction.where(target: @contest, tx_type: "settle_contest").count
  end

  # ── settlement_pending → settled, only on a confirmed signature ──────────

  test "settled_only_on_confirmed_signature: mark_settled! is the one door to settled" do
    make_onchain
    make_entry(score: 100.0)
    grade!
    @contest.reload

    refused = assert_raises(ActiveRecord::RecordInvalid) { @contest.update!(status: "settled") }
    assert_match "only when the settle transaction confirms", refused.message
    assert_equal "settlement_pending", @contest.reload.status

    assert_raises(Contest::Settlement::NotConfirmed) { @contest.mark_settled!("") }
    assert_equal "settlement_pending", @contest.reload.status

    assert_equal true, @contest.mark_settled!(SIGNATURE)

    @contest.reload
    assert_equal "settled", @contest.status
    assert @contest.onchain_settled?
  end

  test "control: a contest that was never graded cannot be marked settled" do
    make_onchain

    assert_raises(Contest::Settlement::NotConfirmed) { @contest.mark_settled!(SIGNATURE) }

    assert_equal "open", @contest.reload.status
    refute @contest.onchain_settled?
  end

  test "mark_settled! clears the failure reason and is safe to repeat" do
    make_onchain
    make_entry(score: 100.0)
    grade!
    @contest.record_settlement_failure!("the first attempt expired")

    assert_equal true, @contest.mark_settled!(SIGNATURE)
    assert_equal false, @contest.mark_settled!(SIGNATURE), "a repeat writes nothing"

    assert_nil @contest.reload.settlement_error
    assert_equal 1, TransactionLog.where(source: @contest).count, "one pointer per paid entry, once"
  end

  # ── the ledger holds a pointer, written at confirmation ──────────────────

  test "confirming writes one payout pointer per paid entry: the signature and no amount" do
    make_onchain
    first = make_entry(score: 100.0)
    second = make_entry(score: 90.0)
    grade!

    @contest.mark_settled!(SIGNATURE)

    rows = TransactionLog.where(source: @contest, transaction_type: "payout").order(:id)
    assert_equal [first.user_id, second.user_id], rows.map(&:user_id)
    assert_equal [SIGNATURE], rows.map(&:onchain_tx).uniq
    assert_equal [nil], rows.map(&:amount_cents).uniq, "the chain is the record of the amount"
    assert rows.all?(&:pointer?)
    assert_equal "Payout rank #1 for #{@contest.name}", rows.first.description
  end

  test "control: a ledger row of any other type still needs its amount, and a pointer needs its signature" do
    user = users(:jordan)

    no_amount = TransactionLog.new(user: user, transaction_type: "deposit", direction: "credit", amount_cents: nil)
    refute no_amount.valid?
    assert_includes no_amount.errors[:amount_cents], "can't be blank"

    no_signature = TransactionLog.new(user: user, transaction_type: "payout", direction: "credit", amount_cents: nil)
    refute no_signature.valid?
    assert_includes no_signature.errors[:onchain_tx], "can't be blank"
  end

  # ── a settle that does not pay stays pending, with its reason ────────────

  test "landed_failure_keeps_pending_with_reason: a settle that failed on chain returns to the queue" do
    tx = broadcast_settle

    verdict = tx.reconcile_broadcast!({ "err" => { "InstructionError" => [0, { "Custom" => 6047 }] },
                                        "confirmationStatus" => "finalized" })

    assert_equal :failed, verdict
    @contest.reload
    assert_equal "settlement_pending", @contest.status, "a failed settle paid nothing"
    assert_match "landed and failed on chain", @contest.settlement_error
    assert_match "6047", @contest.settlement_error
    assert_match SIGNATURE, @contest.settlement_error
    assert_match "Rebuild the settle transaction and cosign it again.", @contest.settlement_error
    assert_equal ["pending", nil], [tx.reload.status, tx.tx_signature], "the row is rebuildable"
    assert_equal 0, TransactionLog.where(source: @contest).count
  end

  test "an expired settle (never landed, blockhash lapsed) returns to the queue with its reason" do
    tx = broadcast_settle(broadcast_at: 10.minutes.ago)

    assert_equal :never_landed, tx.reconcile_broadcast!(nil)

    @contest.reload
    assert_equal "settlement_pending", @contest.status
    assert_match "expired", @contest.settlement_error
    assert_equal "pending", tx.reload.status
  end

  test "control: a settle that may still land is left alone, with no reason written" do
    tx = broadcast_settle(broadcast_at: 30.seconds.ago)

    assert_equal :ambiguous, tx.reconcile_broadcast!(nil)

    assert_equal ["submitted", SIGNATURE], [tx.reload.status, tx.tx_signature]
    assert_nil @contest.reload.settlement_error
    assert_equal "settlement_pending", @contest.status
  end

  test "control: a failed row of another type writes nothing on any contest" do
    make_onchain
    make_entry(score: 100.0)
    grade!
    cancel = PendingTransaction.create!(tx_type: "cancel_contest", serialized_tx: "x", target: @contest,
                                        status: "submitted", tx_signature: "CancelSig#{SecureRandom.hex(8)}",
                                        broadcast_at: 1.minute.ago)

    assert_equal :failed, cancel.reconcile_broadcast!({ "err" => "boom", "confirmationStatus" => "finalized" })

    assert_nil @contest.reload.settlement_error
  end

  # ── what a graded contest reads as ───────────────────────────────────────

  test "a settlement_pending contest reads locked, concluded and not live, and leaves the featured rail" do
    make_onchain
    make_entry(score: 100.0)
    grade!
    @contest.reload

    assert @contest.locked?
    assert @contest.concluded?
    refute @contest.live?
    assert_empty Contest.featured_order([@contest])
    assert_includes Contest.graded, @contest
    assert_includes Contest.listed, @contest
    refute_includes Contest.settled, @contest
  end

  private

  def grade!
    Solana::Vault.stub(:new, settle_vault) do
      @contest.stub(:score_entries!, nil) { @contest.grade! }
    end
  end

  def make_onchain
    @contest.update_columns(onchain_contest_id: EnteredOnchain.random_wallet)
  end

  def settle_vault
    vault = Object.new
    vault.define_singleton_method(:build_settle_contest) do |slug, _winners, **_kw|
      { serialized_tx: Base64.strict_encode64("settle-#{slug}") }
    end
    vault
  end

  def make_entry(score:)
    user = User.create!(email: "settle_#{SecureRandom.hex(4)}@example.com",
                        web3_solana_address: EnteredOnchain.random_wallet)
    Entry.create!(user: user, contest: @contest, status: "active", score: score,
                  **EnteredOnchain.attrs(@contest, user.web3_solana_address))
  end

  # A graded on-chain contest whose settle was cosigned and broadcast, verdict
  # not in: the row is `submitted` under its signature.
  def broadcast_settle(broadcast_at: 1.minute.ago)
    make_onchain
    make_entry(score: 100.0)
    grade!
    tx = @contest.reload.settlement_transaction
    assert tx.claim_for_broadcast!(SIGNATURE)
    tx.update_columns(broadcast_at: broadcast_at)
    tx
  end
end
