require "test_helper"
require "minitest/mock"

# [integration] Contests::SettlementReconciler: a broadcast settle is moved on
# from what the chain says, and its contest with it. Solana::TxVerifier runs
# unstubbed against a real getTransaction shape; only the RPC is stood in.
class Contests::SettlementReconcilerTest < ActiveJob::TestCase
  include SettlementScenario

  SIGNATURE = "SweepSettleSig11111111111111111111111111111111111111111111111111".freeze

  setup do
    @contest = settlement_contest
    @winner = settlement_entry(@contest, score: 100.0)
    settlement_entry(@contest, score: 90.0)
    grade_onchain!(@contest)
    @tx = broadcast_settlement!(@contest, signature: SIGNATURE)
  end

  def reconcile(chain) = Contests::SettlementReconciler.call(@tx, vault: chain)

  def landed_chain(**info)
    Chain.new(statuses: { SIGNATURE => landed_status },
              transactions: { SIGNATURE => settle_transaction_info(account: @contest.onchain_contest_id, **info) })
  end

  test "confirmed_settles: a confirmed signature settles the contest, confirms the row and writes the pointers" do
    chain = landed_chain

    result = nil
    assert_enqueued_jobs(2, only: WinnerNotificationJob) { result = reconcile(chain) }

    assert_equal :settled, result.status
    @contest.reload
    assert_equal "settled", @contest.status
    assert @contest.onchain_settled?
    assert_nil @contest.settlement_error
    assert_equal ["confirmed", SIGNATURE], [@tx.reload.status, @tx.tx_signature]
    assert_equal [Solana::Config::MULTISIG_COSIGNER], @tx.cosigner_addresses, "the signer is read off the chain"
    pointers = TransactionLog.where(source: @contest, transaction_type: "payout")
    assert_equal [[SIGNATURE, nil]] * 2, pointers.pluck(:onchain_tx, :amount_cents)
    assert_empty chain.client.sent_transactions, "the reconciler never sends"
  end

  test "unconfirmed_stays_pending: a signature with no status that can still land changes nothing" do
    @tx.update_columns(broadcast_at: 1.minute.ago)

    result = nil
    assert_no_enqueued_jobs(only: WinnerNotificationJob) { result = reconcile(Chain.new) }

    assert_equal :pending, result.status
    assert_equal "settlement_pending", @contest.reload.status
    assert_nil @contest.settlement_error
    assert_equal ["submitted", SIGNATURE], [@tx.reload.status, @tx.tx_signature]
    assert_equal 0, TransactionLog.where(source: @contest).count
  end

  test "a settle that landed and failed stays settlement_pending with the reason, and the row can be rebuilt" do
    chain = Chain.new(statuses: { SIGNATURE => failed_status(6047) }, contest_status: "Open")

    result = reconcile(chain)

    assert_equal :failed, result.status
    assert_equal ["finalized"], chain.contest_reads
    @contest.reload
    assert_equal "settlement_pending", @contest.status
    refute @contest.onchain_settled?
    assert_match "landed and failed on chain", @contest.settlement_error
    assert_match "6047", @contest.settlement_error
    assert_equal ["pending", nil], [@tx.reload.status, @tx.tx_signature]
    assert_equal 300_00, @winner.reload.payout_cents, "the proposal survives for the retry"
    assert_equal 0, TransactionLog.where(source: @contest).count
  end

  # ── a signature with no status, past its blockhash window ────────────────
  # The contest account at `finalized` decides. No status alone decides nothing.

  def lapsed!(chain)
    @tx.update_columns(broadcast_at: 10.minutes.ago)
    reconcile(chain)
  end

  def assert_row_kept!
    assert_equal ["submitted", SIGNATURE], [@tx.reload.status, @tx.tx_signature], "the row keeps its signature"
  end

  def refute_nothing_was_paid!
    refute_match(/Nothing was paid/, @contest.reload.settlement_error.to_s)
  end

  test "no status and a Settled account: the contest is settled under the row's signature, and no rewind" do
    chain = Chain.new(contest_status: "Settled")

    result = nil
    assert_enqueued_jobs(2, only: WinnerNotificationJob) { result = lapsed!(chain) }

    assert_equal :settled, result.status
    assert_equal ["finalized"], chain.contest_reads, "the account is read at finalized"
    @contest.reload
    assert_equal "settled", @contest.status
    assert @contest.onchain_settled?
    assert_nil @contest.settlement_error
    assert_equal ["confirmed", SIGNATURE], [@tx.reload.status, @tx.tx_signature]
    assert_equal [SIGNATURE] * 2, TransactionLog.where(source: @contest, transaction_type: "payout").pluck(:onchain_tx)
    assert_empty chain.client.sent_transactions
  end

  test "no status, a Settled account and a readable settle: the signers are read off the transaction" do
    chain = Chain.new(contest_status: "Settled",
                      transactions: { SIGNATURE => settle_transaction_info(account: @contest.onchain_contest_id) })

    assert_equal :settled, lapsed!(chain).status
    assert_equal [Solana::Config::MULTISIG_COSIGNER], @tx.reload.cosigner_addresses
  end

  test "no status, a Settled account and a readable transaction that is not this settle: never settled, never rewound" do
    chain = Chain.new(contest_status: "Settled",
                      transactions: { SIGNATURE => settle_transaction_info(account: EnteredOnchain.random_wallet) })

    result = nil
    assert_no_enqueued_jobs(only: WinnerNotificationJob) { result = lapsed!(chain) }

    assert_equal :unverified, result.status
    assert_equal "settlement_pending", @contest.reload.status
    assert_row_kept!
    refute_nothing_was_paid!
  end

  %w[Open Locked].each do |status|
    test "no status and a #{status} account at finalized: the row rewinds with the expiry as the reason" do
      chain = Chain.new(contest_status: status)

      result = lapsed!(chain)

      assert_equal :expired, result.status
      assert_equal ["finalized"], chain.contest_reads
      assert_equal "settlement_pending", @contest.reload.status
      assert_match "expired", @contest.settlement_error
      assert_match "Nothing was paid", @contest.settlement_error
      assert_equal ["pending", nil], [@tx.reload.status, @tx.tx_signature]
    end
  end

  test "no status and an account read that fails: nothing changes" do
    chain = Chain.new(contest_raises: "429 Too Many Requests")

    result = nil
    assert_no_enqueued_jobs(only: WinnerNotificationJob) { result = lapsed!(chain) }

    assert_equal :held, result.status
    assert_equal ["finalized"], chain.contest_reads
    assert_equal "settlement_pending", @contest.reload.status
    assert_nil @contest.settlement_error
    assert_row_kept!
  end

  [nil, "Cancelled", "Unknown"].each do |status|
    test "no status and an account that reads #{status.inspect}: nothing changes" do
      result = lapsed!(Chain.new(contest_status: status))

      assert_equal :held, result.status
      assert_equal "settlement_pending", @contest.reload.status
      assert_nil @contest.settlement_error
      assert_row_kept!
    end
  end

  test "a failed signature and a Settled account: another transaction paid, so no rewind and no retry reason" do
    chain = Chain.new(statuses: { SIGNATURE => failed_status(6047) }, contest_status: "Settled")

    result = nil
    assert_no_enqueued_jobs(only: WinnerNotificationJob) { result = reconcile(chain) }

    assert_equal :unverified, result.status
    assert_equal "settlement_pending", @contest.reload.status
    assert_match "reads Settled on chain", @contest.settlement_error
    assert_row_kept!
    refute_nothing_was_paid!
    assert_equal 0, TransactionLog.where(source: @contest).count
  end

  test "a failed signature and an account read that fails: nothing changes" do
    chain = Chain.new(statuses: { SIGNATURE => failed_status(6047) }, contest_raises: "timeout")

    assert_equal :held, reconcile(chain).status
    assert_nil @contest.reload.settlement_error
    assert_row_kept!
  end

  test "an unreadable chain is not a verdict, however old the broadcast" do
    @tx.update_columns(broadcast_at: 3.days.ago)

    result = reconcile(Chain.new(status_raises: "429 Too Many Requests"))

    assert_equal :unreadable, result.status
    assert_equal ["submitted", SIGNATURE], [@tx.reload.status, @tx.tx_signature]
    assert_equal "settlement_pending", @contest.reload.status
    assert_nil @contest.settlement_error
  end

  test "a landed transaction that does not write this contest is never settled and never rewound" do
    chain = Chain.new(statuses: { SIGNATURE => landed_status },
                      transactions: { SIGNATURE => settle_transaction_info(account: EnteredOnchain.random_wallet) })

    result = nil
    assert_no_enqueued_jobs(only: WinnerNotificationJob) { result = reconcile(chain) }

    assert_equal :unverified, result.status
    @contest.reload
    assert_equal "settlement_pending", @contest.status
    assert_match "could not be verified", @contest.settlement_error
    assert_equal ["submitted", SIGNATURE], [@tx.reload.status, @tx.tx_signature], "it is on chain: no rebuild"
  end

  test "a landed transaction that is not a settle_contest is never settled" do
    result = reconcile(landed_chain(instruction: "cancel_contest"))

    assert_equal :unverified, result.status
    assert_equal "settlement_pending", @contest.reload.status
    assert_equal "submitted", @tx.reload.status
  end

  test "a landed signature the node cannot show yet is asked again" do
    result = reconcile(Chain.new(statuses: { SIGNATURE => landed_status }))

    assert_equal :pending, result.status
    assert_equal "settlement_pending", @contest.reload.status
    assert_nil @contest.settlement_error
    assert_equal "submitted", @tx.reload.status
  end

  test "a landed settle whose contest account does not read Settled yet is asked again" do
    chain = Chain.new(statuses: { SIGNATURE => landed_status }, contest_status: "Open",
                      transactions: { SIGNATURE => settle_transaction_info(account: @contest.onchain_contest_id) })

    assert_equal :pending, reconcile(chain).status
    assert_equal "settlement_pending", @contest.reload.status
    assert_equal "submitted", @tx.reload.status
  end

  test "a verified settle whose contest account is already closed still settles" do
    chain = Chain.new(statuses: { SIGNATURE => landed_status }, contest_status: nil,
                      transactions: { SIGNATURE => settle_transaction_info(account: @contest.onchain_contest_id) })

    assert_equal :settled, reconcile(chain).status
    assert_equal "settled", @contest.reload.status
  end

  test "a verified settle for a contest this app does not hold as graded is left for a person" do
    @contest.update_columns(status: "open")

    result = reconcile(landed_chain)

    assert_equal :ungraded, result.status
    assert_equal "open", @contest.reload.status
    assert_equal ["submitted", SIGNATURE], [@tx.reload.status, @tx.tx_signature]
  end

  test "a row that is not a broadcast settle is left alone without a chain read" do
    @tx.rewind_broadcast!(SIGNATURE)
    chain = Chain.new

    assert_equal :idle, reconcile(chain).status
    assert_empty chain.client.status_calls
  end
end
