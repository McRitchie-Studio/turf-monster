require "test_helper"
require "minitest/mock"

# [integration] Contests::SettlementSweepJob: every broadcast settle is settled
# from the chain. No row moves by its age alone.
class Contests::SettlementSweepJobTest < ActiveJob::TestCase
  include SettlementScenario

  SIGNATURE = "SweepJobSettleSig111111111111111111111111111111111111111111111111".freeze

  setup do
    @contest = settlement_contest(name: "Sweep job")
    settlement_entry(@contest, score: 100.0)
    grade_onchain!(@contest)
  end

  def sweep(chain) = Solana::Vault.stub(:new, chain) { Contests::SettlementSweepJob.perform_now }

  def landed_chain
    Chain.new(statuses: { SIGNATURE => landed_status },
              transactions: { SIGNATURE => settle_transaction_info(account: @contest.onchain_contest_id) })
  end

  test "confirmed_settles: the sweep marks a confirmed settle settled" do
    tx = broadcast_settlement!(@contest, signature: SIGNATURE)

    stats = sweep(landed_chain)

    assert_equal 1, stats[:settled]
    assert_equal "settled", @contest.reload.status
    assert_equal "confirmed", tx.reload.status
  end

  test "unconfirmed_stays_pending: an unconfirmed settle stays pending, and a failed one carries its reason" do
    tx = broadcast_settlement!(@contest, signature: SIGNATURE, broadcast_at: 1.minute.ago)

    assert_equal 1, sweep(Chain.new)[:pending]
    assert_equal ["settlement_pending", nil], [@contest.reload.status, @contest.settlement_error]
    assert_equal "submitted", tx.reload.status

    assert_equal 1, sweep(Chain.new(statuses: { SIGNATURE => failed_status }, contest_status: "Open"))[:failed]
    assert_equal "settlement_pending", @contest.reload.status
    assert_match "landed and failed on chain", @contest.settlement_error
    assert_equal "pending", tx.reload.status, "visible in the cosign queue for a rebuild"
  end

  test "age alone moves nothing: a days-old broadcast with an unreadable chain is left as it is" do
    tx = broadcast_settlement!(@contest, signature: SIGNATURE, broadcast_at: 3.days.ago)

    stats = sweep(Chain.new(status_raises: "503"))

    assert_equal 1, stats[:unreadable]
    assert_equal ["submitted", SIGNATURE], [tx.reload.status, tx.tx_signature]
    assert_equal "settlement_pending", @contest.reload.status
  end

  test "a row the broadcasting request may still hold is not swept" do
    tx = broadcast_settlement!(@contest, signature: SIGNATURE, broadcast_at: 10.seconds.ago)
    chain = landed_chain

    stats = sweep(chain)

    assert_equal 0, stats[:settled]
    assert_empty chain.client.status_calls
    assert_equal "submitted", tx.reload.status
  end

  test "an unsigned settle waiting on its cosign costs no vault and no chain read" do
    stats = Solana::Vault.stub(:new, -> { flunk "the sweep built a vault with nothing submitted" }) do
      Contests::SettlementSweepJob.perform_now
    end

    assert_equal({ healed: 0 }, stats.to_h)
    assert_equal "pending", @contest.settlement_transaction.status
    assert_equal "settlement_pending", @contest.reload.status
  end

  test "a confirmed settle whose contest write did not finish is healed from the row" do
    tx = broadcast_settlement!(@contest, signature: SIGNATURE)
    tx.update_columns(status: "confirmed")

    stats = Solana::Vault.stub(:new, -> { flunk "healing needs no chain read" }) do
      Contests::SettlementSweepJob.perform_now
    end

    assert_equal 1, stats[:healed]
    assert_equal "settled", @contest.reload.status
    assert_equal [SIGNATURE], TransactionLog.where(source: @contest).pluck(:onchain_tx)
  end

  test "one row that raises does not stop the rest" do
    broadcast_settlement!(@contest, signature: SIGNATURE)
    other = settlement_contest(name: "Sweep job second")
    settlement_entry(other, score: 100.0)
    grade_onchain!(other)
    other_tx = broadcast_settlement!(other, signature: "#{SIGNATURE}b", broadcast_at: 5.minutes.ago)
    chain = Chain.new(statuses: { SIGNATURE => landed_status, "#{SIGNATURE}b" => landed_status },
                      transactions: { SIGNATURE => settle_transaction_info(account: @contest.onchain_contest_id) })
    chain.client.define_singleton_method(:confirm_transaction) do |signature|
      raise "boom" if signature.end_with?("b")

      { "value" => [{ "err" => nil, "confirmationStatus" => "finalized" }] }
    end

    stats = sweep(chain)

    assert_equal({ healed: 0, error: 1, settled: 1 }, stats.to_h)
    assert_equal "settled", @contest.reload.status
    assert_equal "submitted", other_tx.reload.status
  end
end
