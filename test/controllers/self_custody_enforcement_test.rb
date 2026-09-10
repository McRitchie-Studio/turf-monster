require "test_helper"
require "minitest/mock"

# Stage 3 enforcement: every code path that would server-sign for a managed
# user MUST refuse to do so once users.self_custodied_at is set.
#
# Today's enforcement points:
#   - ContestsController#enter           — explicit 422 before the managed branch
#   - AccountsController#update_username — route to the co-sign path (build_set_username
#                                          returns a partial TX for the user to sign)
class SelfCustodyEnforcementTest < ActionDispatch::IntegrationTest
  setup do
    @user = User.create!(
      name: "Self Custody Sam", username: "sc-sam-#{SecureRandom.hex(2)}",
      email: "sc-#{SecureRandom.hex(2)}@example.test",
      email_verified_at: Time.current
    )
    # Custodial by design — this suite is the enforcement around a managed
    # wallet, which signup no longer mints (web3-only onboarding, 2026-08-15).
    grant_managed_wallet!(@user)
    assert @user.reload.managed_wallet?

    @contest = Contest.create!(
      name: "Onchain Smoke",
      entry_fee_cents: 100,
      max_entries: 100,
      status: :open,
      contest_type: "standard",
      slate: Slate.first || Slate.create!(name: "Smoke Slate"),
      onchain_contest_id: SecureRandom.hex(8),  # marks it as onchain — the entry path checks @contest.onchain?
      rank: 999
    )
  end

  test "ContestsController#enter refuses with self_custodied flag once the user has exported" do
    @user.update!(self_custodied_at: 1.minute.ago)
    log_in_as(@user)

    post enter_contest_path(@contest), params: {}, as: :json
    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_not body["success"]
    assert body["self_custodied"], "response must flag self_custodied so the client knows to redirect to Phantom sign-in"
    assert_match(/self-custodied/i, body["error"])
    assert_match(/sign in with phantom/i, body["error"])
  end

  test "ContestsController#enter still works for a NON self-custodied managed user (this guard is the only addition)" do
    # The pre-existing managed-entry path still runs for users who haven't
    # gone through the export flow. We're not asserting it succeeds here
    # (the full onchain stack is mocked by the rest of the suite via
    # test/support/fake_vault); we only assert that the guard added in
    # Stage 3 does NOT engage for users with self_custodied_at = nil.
    refute @user.self_custodied?
    log_in_as(@user)

    post enter_contest_path(@contest), params: {}, as: :json
    # Whatever the response is, it MUST NOT be the new self-custody 422 —
    # the message + flag would be present if the guard accidentally matched.
    body = JSON.parse(response.body) rescue {}
    refute body["self_custodied"], "non-self-custodied users must not hit the self-custody guard"
  end

  test "AccountsController#update_username routes self-custodied user to the co-sign path" do
    # Give the user an Entry so can_change_username? returns true.
    Entry.create!(user: @user, contest: @contest, status: :active)
    @user.update!(self_custodied_at: 1.minute.ago)
    log_in_as(@user)

    # Stub the on-chain transaction-build so the test doesn't need a live
    # Solana RPC. The KEY assertion is that we hit build_set_username
    # (the co-sign path), NOT set_username (the server-sign path).
    fake_vault = Object.new
    fake_vault.define_singleton_method(:build_set_username) do |_addr, _name|
      { serialized_tx: "fake-base64-tx" }
    end
    Solana::Vault.stub :new, fake_vault do
      post update_username_account_path,
           params: { value: "newname#{SecureRandom.hex(2)}" },
           as: :json
    end
    assert_response :success
    body = JSON.parse(response.body)
    assert_equal "needs_step", body["status"], "self-custodied user must be routed to the partial-tx + co-sign path"
    assert_equal "fake-base64-tx", body["challenge"]
    assert body["token"].present?
  end

  test "AccountsController#update_username still server-signs for a NON self-custodied managed user" do
    Entry.create!(user: @user, contest: @contest, status: :active)
    refute @user.self_custodied?
    log_in_as(@user)

    # Stub the server-sign path. If our guard mis-routes a managed user to
    # build_set_username we'd see needs_signature in the response.
    fake_vault = Object.new
    fake_vault.define_singleton_method(:set_username) do |_addr, _name, **_opts|
      true
    end
    Solana::Vault.stub :new, fake_vault do
      post update_username_account_path,
           params: { value: "newname#{SecureRandom.hex(2)}" },
           as: :json
    end
    assert_response :success
    body = JSON.parse(response.body)
    refute_equal "needs_step", body["status"], "non-self-custodied managed user must stay on the server-sign path"
    assert_equal "saved", body["status"]
  end

end
