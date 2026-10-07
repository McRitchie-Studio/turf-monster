require "test_helper"

# Approving a withdrawal re-checks the user's balance in base units, both sides
# integers: 201 cents against exactly 2_010_000 passes, one unit less refuses.
class TransactionLogsApproveExactTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @user = users(:sam)
  end

  test "the approve-time balance check is exact to the base unit" do
    log_in_as(@admin)
    { 2_010_000 => "approved", 2_009_999 => "pending" }.each do |balance, status|
      txn = TransactionLog.record!(user: @user, type: "withdrawal", amount_cents: 2_01, direction: "debit",
                                   status: "pending", description: "Withdrawal request $2.01")
      vault = Object.new
      vault.define_singleton_method(:sync_balance) { |_addr| { balance: balance, balance_dollars: BigDecimal(balance) / 1_000_000 } }

      Solana::Vault.stub(:new, vault) { post admin_transaction_approve_path(txn.slug) }

      assert_equal status, txn.reload.status, "balance #{balance}"
    end
  end
end
