require "test_helper"
require "minitest/mock"

# Coverage for the on-chain contest lifecycle admin actions added in the
# unused-instructions cleanup: close_onchain (1-of-3 server-signed) and
# cancel_onchain (2-of-3 → PendingTransaction). Solana::Vault is stubbed via
# the shared FakeVault so nothing hits RPC.
class ContestsOnchainLifecycleTest < ActionDispatch::IntegrationTest
  setup do
    @admin   = users(:alex)   # admin per db/seeds
    @user    = users(:sam)
    @contest = contests(:one)
  end

  # --- close_onchain ---

  test "close_onchain reclaims rent and flips onchain_closed for a settled contest" do
    @contest.update!(status: :settled, onchain_contest_id: "onchain_close")
    log_in_as(@admin)

    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post close_onchain_contest_path(@contest)
    end

    assert_response :redirect
    assert @contest.reload.onchain_closed?
    assert_equal [@contest.slug], vault.close_calls
  end

  test "close_onchain works for a cancelled (not settled) contest" do
    @contest.update!(status: :open, onchain_contest_id: "onchain_close2", onchain_cancelled: true)
    log_in_as(@admin)

    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post close_onchain_contest_path(@contest)
    end

    assert_response :redirect
    assert @contest.reload.onchain_closed?
  end

  test "close_onchain refuses an open, non-cancelled contest" do
    @contest.update!(status: :open, onchain_contest_id: "onchain_open")
    log_in_as(@admin)

    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post close_onchain_contest_path(@contest)
    end

    assert_response :redirect
    assert_not @contest.reload.onchain_closed?
    assert_equal [], vault.close_calls
  end

  test "close_onchain is a no-op when already closed" do
    @contest.update!(status: :settled, onchain_contest_id: "onchain_done", onchain_closed: true)
    log_in_as(@admin)

    vault = FakeVault.new
    Solana::Vault.stub :new, vault do
      post close_onchain_contest_path(@contest)
    end

    assert_equal [], vault.close_calls
  end

  test "close_onchain requires admin" do
    @contest.update!(status: :settled, onchain_contest_id: "onchain_x")
    log_in_as(@user)
    post close_onchain_contest_path(@contest)
    assert_response :redirect
    assert_not @contest.reload.onchain_closed?
  end

  # --- cancel_onchain ---

  test "cancel_onchain queues a PendingTransaction with the on-chain creator" do
    @contest.update!(status: :open, onchain_contest_id: "onchain_cancel")
    log_in_as(@admin)

    vault = FakeVault.new
    vault.read_contest_creator = "OnChainCreatorXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"

    assert_difference -> { PendingTransaction.count }, 1 do
      Solana::Vault.stub :new, vault do
        post cancel_onchain_contest_path(@contest)
      end
    end

    assert_response :redirect
    ptx = PendingTransaction.order(:created_at).last
    assert_equal "cancel_contest", ptx.tx_type
    assert_equal @contest, ptx.target
    assert_equal "OnChainCreatorXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX", ptx.parsed_metadata["creator"]
    assert_equal "OnChainCreatorXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX", vault.cancel_calls.first[:creator]
  end

  test "cancel_onchain refuses a settled contest" do
    @contest.update!(status: :settled, onchain_contest_id: "onchain_settled")
    log_in_as(@admin)

    vault = FakeVault.new
    assert_no_difference -> { PendingTransaction.count } do
      Solana::Vault.stub :new, vault do
        post cancel_onchain_contest_path(@contest)
      end
    end
    assert_equal [], vault.cancel_calls
  end

  test "cancel_onchain refuses an already-cancelled contest" do
    @contest.update!(status: :open, onchain_contest_id: "onchain_c", onchain_cancelled: true)
    log_in_as(@admin)

    vault = FakeVault.new
    assert_no_difference -> { PendingTransaction.count } do
      Solana::Vault.stub :new, vault do
        post cancel_onchain_contest_path(@contest)
      end
    end
  end

  test "cancel_onchain requires admin" do
    @contest.update!(status: :open, onchain_contest_id: "onchain_y")
    log_in_as(@user)
    assert_no_difference -> { PendingTransaction.count } do
      post cancel_onchain_contest_path(@contest)
    end
  end

  # --- entry guards reject cancelled contests ---

  test "enter rejects a cancelled contest" do
    @contest.update!(status: :open, onchain_contest_id: "onchain_e", onchain_cancelled: true)
    log_in_as(@user)
    post enter_contest_path(@contest), as: :json
    assert_response :unprocessable_entity
    assert_match(/cancelled/i, JSON.parse(response.body)["error"])
  end
end
