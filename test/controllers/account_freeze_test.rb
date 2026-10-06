require "test_helper"

# B4 / OPSEC-048: account freeze blocks money-moving actions on disputed users.
class AccountFreezeTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:alex)
    log_in_as(@user)
  end

  test "frozen user is blocked from contest entry POSTs" do
    @user.freeze_for_payment_risk!(reason: "test")
    contest = contests(:one)

    post enter_contest_path(contest)

    assert_redirected_to account_path
    assert_match(/frozen/i, flash[:alert])
  end

  test "frozen user is blocked from buying tokens" do
    @user.freeze_for_payment_risk!(reason: "test")

    post tokens_stripe_checkout_path, params: { pack: "trio" }

    assert_redirected_to account_path
    assert_match(/frozen/i, flash[:alert])
  end

  test "frozen user is blocked from withdrawing" do
    @user.freeze_for_payment_risk!(reason: "test")

    post withdraw_wallet_path, params: { amount: 10 }

    assert_redirected_to account_path
    assert_match(/frozen/i, flash[:alert])
  end

  test "frozen user can still view read-only account page" do
    @user.freeze_for_payment_risk!(reason: "test")

    get account_path
    assert_response :success
  end

  test "unfreeze restores normal access" do
    @user.freeze_for_payment_risk!(reason: "test")
    assert @user.reload.frozen?

    @user.unfreeze!
    assert_not @user.reload.frozen?
  end

  test "double-freeze is idempotent (does not overwrite frozen_at or reason)" do
    @user.freeze_for_payment_risk!(reason: "first")
    first_frozen_at = @user.reload.frozen_at

    travel 1.minute do
      @user.freeze_for_payment_risk!(reason: "second")
    end

    assert_equal first_frozen_at.to_i, @user.reload.frozen_at.to_i
    assert_equal "first", @user.frozen_reason
  end
end
