require "test_helper"
require "minitest/mock"

# Web2 withdraw flow (Stage 1 — UI + queue, no off-ramp yet).
#
# Stage 2 (separate engagement): replace the manual operator handoff
# with an automated Stripe Connect / Bridge.xyz / Kraken integration
# that signs the user's managed-wallet ATA → off-ramp provider transfer
# from the encrypted_web2_solana_private_key.
class WalletsWithdrawTest < ActionDispatch::IntegrationTest
  setup do
    @managed = User.create!(
      name: "Withdraw Wendy", username: "wd-#{SecureRandom.hex(2)}",
      email: "wd-#{SecureRandom.hex(2)}@example.test",
      email_verified_at: Time.current
    )
    grant_managed_wallet!(@managed)
    assert @managed.reload.managed_wallet?

    # Stub sync_balance to return $50 available. The controller calls this
    # via Solana::Vault.new.sync_balance(address) — easier to stub the
    # whole Vault.new than to mock the RPC.
    @fake_vault = Object.new
    @available_dollars = 50.00
    avail = @available_dollars
    @fake_vault.define_singleton_method(:sync_balance) do |_addr|
      { balance_dollars: avail }
    end
  end

  test "happy path: managed user submits valid withdrawal" do
    log_in_as(@managed)
    Solana::Vault.stub :new, @fake_vault do
      assert_difference -> { TransactionLog.where(user: @managed, transaction_type: "withdrawal").count }, +1 do
        post withdraw_wallet_path,
             params: { amount: "25.00", destination_info: "Stripe email alex@example.com" }
      end
    end
    assert_redirected_to wallet_path
    follow_redirect!
    assert_match(/submitted for review/i, flash[:notice].to_s + response.body)

    txn = TransactionLog.where(user: @managed, transaction_type: "withdrawal").order(created_at: :desc).first
    assert_equal "pending", txn.status
    assert_equal 2500, txn.amount_cents
    assert_equal "debit", txn.direction
    assert_equal "Stripe email alex@example.com", txn.metadata["destination_info"]
    assert txn.metadata["requested_at"].present?
    assert txn.metadata["requested_from_ip"].present?
  end

  test "missing amount is rejected" do
    log_in_as(@managed)
    Solana::Vault.stub :new, @fake_vault do
      assert_no_difference -> { TransactionLog.count } do
        post withdraw_wallet_path, params: { amount: "", destination_info: "foo" }
      end
    end
    assert_redirected_to wallet_path
    follow_redirect!
    assert_match(/invalid amount/i, flash[:alert].to_s)
  end

  test "missing destination_info is rejected" do
    log_in_as(@managed)
    Solana::Vault.stub :new, @fake_vault do
      assert_no_difference -> { TransactionLog.count } do
        post withdraw_wallet_path, params: { amount: "10.00", destination_info: "" }
      end
    end
    assert_redirected_to wallet_path
    follow_redirect!
    assert_match(/where to send/i, flash[:alert].to_s)
  end

  test "overlong destination_info is rejected (operator-side typo guard)" do
    log_in_as(@managed)
    Solana::Vault.stub :new, @fake_vault do
      assert_no_difference -> { TransactionLog.count } do
        post withdraw_wallet_path, params: { amount: "10.00", destination_info: "x" * 501 }
      end
    end
    follow_redirect!
    assert_match(/too long/i, flash[:alert].to_s)
  end

  test "withdrawal exceeding on-chain balance is rejected" do
    log_in_as(@managed)
    Solana::Vault.stub :new, @fake_vault do
      assert_no_difference -> { TransactionLog.count } do
        post withdraw_wallet_path,
             params: { amount: "100.00", destination_info: "Stripe email a@b.com" }
      end
    end
    follow_redirect!
    assert_match(/exceeds on-chain balance/i, flash[:alert].to_s)
  end

  test "self-custodied user is refused" do
    @managed.update!(self_custodied_at: 1.minute.ago)
    log_in_as(@managed)
    Solana::Vault.stub :new, @fake_vault do
      assert_no_difference -> { TransactionLog.count } do
        post withdraw_wallet_path,
             params: { amount: "10.00", destination_info: "Stripe email a@b.com" }
      end
    end
    follow_redirect!
    assert_match(/self-custodied/i, flash[:alert].to_s)
  end

  test "wallet page shows the Withdraw button for a managed non-self-custodied user" do
    log_in_as(@managed)
    Solana::Vault.stub :new, @fake_vault do
      get wallet_path
    end
    assert_response :success
    assert_select "h2", text: /Cash out/
    # The collapse trigger is a button with text "Withdraw" or "Cancel"
    assert_match(/x-text="open \? 'Cancel' : 'Withdraw'"/, response.body)
  end

  test "wallet page hides the Withdraw card for a self-custodied user and shows the callout" do
    @managed.update!(self_custodied_at: 1.minute.ago)
    log_in_as(@managed)
    Solana::Vault.stub :new, @fake_vault do
      get wallet_path
    end
    assert_response :success
    # The withdraw form's destination-info textarea must NOT render.
    assert_no_match(/destination_info/, response.body)
    # The self-custody callout text must render instead.
    assert_match(/you're self-custodied/i, response.body)
    assert_match(/directly from the wallet you imported/i, response.body)
  end

end
