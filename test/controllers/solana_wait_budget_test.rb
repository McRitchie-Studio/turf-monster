require "test_helper"
require "minitest/mock"

# EACH WIRED PATH RUNS UNDER ITS BUDGET (turf-wires-rpc-wait-budgets).
#
# solana-studio 0.12.3 bounds the seconds one RPC call may spend waiting
# between retries, and the bound is THREAD-LOCAL
# (Solana::Client.with_wait_budget). So the test that matters is not "the
# constant exists" but "at the moment the RPC would run, THIS thread carries
# THIS budget". Every double below reads Thread.current at that moment.
class SolanaWaitBudgetTest < ActionDispatch::IntegrationTest
  KEY = Solana::Client::WAIT_BUDGET_KEY

  # Swap SolanaWaitBudget::REQUEST for one block, restoring it after.
  def with_request_budget(seconds)
    original = SolanaWaitBudget::REQUEST
    SolanaWaitBudget.send(:remove_const, :REQUEST)
    SolanaWaitBudget.const_set(:REQUEST, seconds)
    yield
  ensure
    SolanaWaitBudget.send(:remove_const, :REQUEST)
    SolanaWaitBudget.const_set(:REQUEST, original)
  end

  def budget_now
    Thread.current[KEY]
  end

  # A FakeVault that writes down the budget each RPC-shaped call ran under.
  class BudgetVault < FakeVault
    attr_reader :budgets

    def initialize(...)
      super(...)
      @budgets = Hash.new { |h, k| h[k] = [] }
      @budget_lock = Mutex.new
    end

    def record(name)
      @budget_lock.synchronize { @budgets[name] << Thread.current[Solana::Client::WAIT_BUDGET_KEY] }
    end

    def fetch_wallet_balances(*, **)
      record(:fetch_wallet_balances)
      super
    end

    def sync_balance(*)
      record(:sync_balance)
      super
    end

    def list_entry_tokens(*, **)
      record(:list_entry_tokens)
      super
    end

    def ensure_user_account(*, **)
      record(:ensure_user_account)
      super
    end

    def next_free_entry_index(*, **)
      record(:next_free_entry_index)
      super
    end
  end

  setup do
    @user = users(:sam)
    @contest = contests(:one)
    SeasonConfig.set_current!(1)
  end

  # ── The request default ────────────────────────────────────────────────

  test "every web, API and MCP request runs inside the request budget" do
    [ApplicationController, Api::V1::BaseController, McpController].each do |klass|
      assert_includes klass.ancestors, SolanaWaitBudget, klass.name
      callbacks = klass._process_action_callbacks.map(&:filter)
      assert_includes callbacks, :run_under_solana_wait_budget, klass.name
    end
    assert_equal 5, SolanaWaitBudget::REQUEST
  end

  test "the request budget wraps the before_actions that can read the chain" do
    chain = ApplicationController._process_action_callbacks.map(&:filter)
    at = chain.index(:run_under_solana_wait_budget)
    %i[verify_session_token set_current_context preload_navbar_solana_data].each do |later|
      assert_operator at, :<, chain.index(later), "#{later} must run inside the budget"
    end
    assert_equal :around, ApplicationController._process_action_callbacks.to_a[at].kind
  end

  # ── Navbar hydrate: 2s inside EACH thread ──────────────────────────────

  test "each navbar hydrate thread runs its read under the 2s hydrate budget" do
    # A web2 address too, so the entry-token thread has a wallet to read.
    @user.update!(web2_solana_address: "Web2BudgetWallet#{SecureRandom.hex(4)}")
    log_in_as(@user)
    vault = BudgetVault.new(usdc_balance: 1.0)

    Solana::Vault.stub :new, vault do
      get session_refresh_account_path, as: :json
    end

    assert_response :success
    %i[fetch_wallet_balances sync_balance list_entry_tokens].each do |read|
      assert_equal [2.0], vault.budgets[read], "#{read} must run under NAVBAR_HYDRATE inside its own thread"
    end
  end

  test "CONTROL: a bare Thread.new does not inherit the request's budget" do
    # Why the hydrate threads open their own block: the budget is thread-local.
    Solana::Client.with_wait_budget(5) do
      assert_equal 5.0, budget_now
      assert_nil Thread.new { Thread.current[KEY] }.value
    end
    assert_nil budget_now, "the block restores the outer (absent) budget"
  end

  # ── Entry preamble: ensure_user_account at 5s ──────────────────────────

  test "prepare_entry runs ensure_user_account under its own budget, and the other reads under the request's" do
    @user.update!(web3_solana_address: "Web3BudgetWallet#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_budget", season_id: 1)
    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart)
    %i[m1 m2 m3 m4 m5 m6].each { |m| entry.selections.create!(slate_matchup: slate_matchups(m)) }

    # ENSURE_USER_ACCOUNT and REQUEST are both 5 today, so the request default
    # is moved to 7 for this request: a preamble that lost its own block would
    # then read 7.0, not pass by coincidence.
    vault = BudgetVault.new
    with_request_budget(7) do
      Solana::Vault.stub :new, vault do
        post prepare_entry_contest_path(@contest), as: :json
      end
    end

    assert_response :success
    assert_equal [SolanaWaitBudget::ENSURE_USER_ACCOUNT.to_f], vault.budgets[:ensure_user_account]
    assert_equal [7.0], vault.budgets[:next_free_entry_index].uniq,
                 "a read with no budget of its own runs under the request default"
  end

  # ── Jobs keep the gem default ──────────────────────────────────────────

  test "outside a request no budget is set, so a job's client uses its own 15s default" do
    assert_nil budget_now
    assert_equal Solana::Client::DEFAULT_WAIT_BUDGET, Solana::Config.client.wait_budget
    assert_equal 15.0, Solana::Config.client.wait_budget
  end

  test "Config.client takes a wait_budget for a caller that wants its own" do
    assert_equal 3.0, Solana::Config.client(wait_budget: 3).wait_budget
    assert_raises(ArgumentError) { Solana::Config.client(wait_budget: -1) }
  end
end
