require "test_helper"
require "minitest/mock"

# A SUSTAINED 429 ON A REQUEST PATH ANSWERS INSIDE THE BUDGET, WITH A CLEAR
# ERROR, NOT A 500 (turf-wires-rpc-wait-budgets).
#
# The RPC here is the gem's real Solana::Client, retry loop and all; only its
# wire answers 429 forever and its sleeps are recorded rather than slept
# (test/support/throttled_rpc.rb). The provider asks for Retry-After: 3, so:
#
#   gem default, 15s : waits 3 + 3 + 3 (three retries, about 10s)   <- CONTROL
#   request,      5s : waits 3 once, then stops                      (entry preamble)
#   hydrate,      2s : waits nothing, stops at once                   (navbar threads)
#
# Before this task the entry preamble's account read waited the full ~10s on
# its own, and the page made several such calls in one request.
class RpcSustained429RequestBudgetTest < ActionDispatch::IntegrationTest
  # Every Vault RPC this double makes goes through ONE throttled client.
  class ThrottledVault < FakeVault
    attr_reader :rpc

    def initialize(rpc, **opts)
      super(**opts)
      @rpc = rpc
    end

    def ensure_user_account(wallet, username: nil)
      @rpc.get_account_info(wallet) # the real first step: check_user_account_status
    end

    def fetch_wallet_balances(wallet, **)
      @rpc.get_token_accounts_by_owner(wallet)
    end

    def sync_balance(wallet)
      @rpc.get_account_info(wallet)
    end

    def list_entry_tokens(wallet, **)
      @rpc.get_token_accounts_by_owner(wallet)
    end
  end

  setup do
    @user = users(:sam)
    @contest = contests(:one)
    SeasonConfig.set_current!(1)
  end

  test "CONTROL: outside a request the same 429 waits out all three retries" do
    rpc = ThrottledRpc.client(retry_after: 3)

    error = assert_raises(Solana::Client::HttpError) { rpc.get_account_info("Wallet") }

    assert_equal 429, error.code
    assert_equal 3, rpc.slept.size
    assert_operator rpc.slept.sum, :>, SolanaWaitBudget::REQUEST, "this is the wait the budget exists to cut"
    assert_equal false, error.call_stats.budget_stopped
  end

  test "prepare_entry under a sustained 429 answers 422 with a clear message, inside the budget" do
    @user.update!(web3_solana_address: "Web3ThrottledWallet#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_throttled", season_id: 1)
    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart)
    %i[m1 m2 m3 m4 m5 m6].each { |m| entry.selections.create!(slate_matchup: slate_matchups(m)) }

    rpc = ThrottledRpc.client(retry_after: 3)
    Solana::Vault.stub :new, ThrottledVault.new(rpc) do
      assert_no_difference "PendingTransaction.count" do
        post prepare_entry_contest_path(@contest), as: :json
      end
    end

    assert_response :unprocessable_entity
    body = JSON.parse(response.body)
    assert_equal false, body["success"]
    assert_equal Entries::PaymentCopy.message(:rpc_unreachable), body["error"]
    refute_match(/HTTP 429|Too many requests/, body["error"], "the raw RPC string must not reach the player")

    assert_operator rpc.slept.sum, :<=, SolanaWaitBudget::ENSURE_USER_ACCOUNT
    assert_equal 1, rpc.slept.size, "one 3s wait fits the 5s budget, the second does not"

    row = OutboundRequest.where(service: "solana_rpc", method: "getAccountInfo").last
    assert_equal "Solana::Client::HttpError", row.error_class
    assert_equal true, row.request_body["budget_stopped"]
    assert_equal 1, row.request_body["retries"]
    assert entry.reload.cart?, "a refused entry stays in the cart"
  end

  test "session_refresh under a sustained 429 answers 200 with unknown balances, waiting nothing" do
    @user.update!(web2_solana_address: "Web2ThrottledWallet#{SecureRandom.hex(4)}")
    log_in_as(@user)

    rpc = ThrottledRpc.client(retry_after: 3)
    Solana::Vault.stub :new, ThrottledVault.new(rpc) do
      get session_refresh_account_path, as: :json
    end

    assert_response :success
    body = JSON.parse(response.body)
    assert_nil body["usdc"], "a throttled read is reported as unknown (null), never as $0"
    assert_nil body["tokens"]
    assert_empty rpc.slept, "a 3s wait does not fit the 2s hydrate budget, so no thread sleeps"

    rows = OutboundRequest.where(service: "solana_rpc").order(:id).last(3)
    assert_equal 3, rows.size
    rows.each do |row|
      assert_equal true, row.request_body["budget_stopped"]
      assert_equal 2_000, row.request_body["budget_ms"]
    end
  end
end
