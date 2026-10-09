require "test_helper"

# [integration] A payout row is a pointer (TransactionLog#pointer?): the settle
# signature and no amount. The admin ledger renders it as a link to the
# transaction; a row with an amount still shows the amount.
class TransactionLogsPointerTest < ActionDispatch::IntegrationTest
  SIGNATURE = "PointerSig111111111111111111111111111111111111111111111111111111".freeze

  setup do
    @pointer = TransactionLog.record!(user: users(:jordan), type: "payout", amount_cents: nil, direction: "credit",
                                      source: contests(:one), onchain_tx: SIGNATURE, description: "Payout rank #1")
    @deposit = TransactionLog.record!(user: users(:jordan), type: "deposit", amount_cents: 12_34, direction: "credit")
    log_in_as(users(:alex))
  end

  test "the ledger index and detail render a pointer as a link to its transaction, with no amount" do
    get admin_transactions_path
    assert_response :success
    assert_select "a[href*='explorer.solana.com/tx/#{SIGNATURE}']", text: "Paid on chain"
    assert_includes response.body, "+$12.34", "control: a row with an amount shows it"

    get admin_transaction_path(slug: @pointer.slug)
    assert_response :success
    assert_select "a[href*='explorer.solana.com/tx/#{SIGNATURE}']", text: "Paid on chain"
  end

  test "payout pointers add nothing to the ledger's payout total" do
    get admin_transactions_path

    assert_response :success
    assert_equal 0, TransactionLog.by_type("payout").completed.sum(:amount_cents)
    assert_nil @pointer.amount_dollars
    assert_equal 12.34, @deposit.amount_dollars
  end
end
