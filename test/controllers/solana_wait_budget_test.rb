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
    attr_reader :budgets, :deadlines

    def initialize(...)
      super(...)
      @budgets = Hash.new { |h, k| h[k] = [] }
      @deadlines = Hash.new { |h, k| h[k] = [] }
      @budget_lock = Mutex.new
    end

    def record(name)
      @budget_lock.synchronize do
        @budgets[name] << Thread.current[Solana::Client::WAIT_BUDGET_KEY]
        @deadlines[name] << Solana::Deadline.remaining
      end
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

  # ── The request deadline ───────────────────────────────────────────────

  # A vault whose account preamble reads the chain ten times and tolerates
  # each failed read, as a page of several balances does.
  class TolerantReadsVault < FakeVault
    def initialize(rpc)
      super()
      @rpc = rpc
    end

    def ensure_user_account(wallet, username: nil)
      10.times do
        @rpc.get_account_info(wallet)
      rescue Solana::Client::HttpError
        nil
      end
    end
  end

  def post_throttled_prepare_entry(now)
    @user.update!(web3_solana_address: "Web3DeadlineWallet#{SecureRandom.hex(4)}")
    @contest.update!(onchain_contest_id: "onchain_deadline", season_id: 1)
    log_in_as_onchain(@user)
    entry = @contest.entries.create!(user: @user, status: :cart)
    %i[m1 m2 m3 m4 m5 m6].each { |m| entry.selections.create!(slate_matchup: slate_matchups(m)) }

    rpc = ThrottledRpc.client(retry_after: 3, on_sleep: ->(seconds) { now[0] += seconds })
    Solana::Deadline.stub :clock, -> { now[0] } do
      Solana::Vault.stub :new, TolerantReadsVault.new(rpc) do
        post prepare_entry_contest_path(@contest), as: :json
      end
    end
    rpc
  end

  test "throttled reads in one request answer 503 RPC_DEADLINE before 25 seconds of waits" do
    now = [5_000.0]

    rpc = post_throttled_prepare_entry(now)

    assert_response :service_unavailable
    body = JSON.parse(response.body)
    assert_equal "RPC_DEADLINE", body["error_code"]
    assert_match(/Nothing was sent/, body["error"])
    assert_equal Solana::Deadline::RETRY_AFTER.to_s, response.headers["Retry-After"]
    assert_operator rpc.slept.size, :>=, 3
    assert_operator rpc.slept.sum, :<=, Solana::Deadline::WEB
    assert_operator now[0] - 5_000.0, :<=, Solana::Deadline::WEB
  end

  test "CONTROL: with no deadline the same request waits past 25 seconds" do
    now = [5_000.0]

    rpc = Solana::Deadline.stub(:remaining, nil) { post_throttled_prepare_entry(now) }

    assert_response :success
    assert_equal 10, rpc.slept.size
    assert_operator rpc.slept.sum, :>, Solana::Deadline::WEB
  end

  test "each navbar hydrate thread runs under the request's deadline" do
    @user.update!(web2_solana_address: "Web2DeadlineWallet#{SecureRandom.hex(4)}")
    log_in_as(@user)
    vault = BudgetVault.new(usdc_balance: 1.0)

    Solana::Vault.stub :new, vault do
      get session_refresh_account_path, as: :json
    end

    assert_response :success
    %i[fetch_wallet_balances sync_balance list_entry_tokens].each do |read|
      left = vault.deadlines[read].first
      assert_not_nil left, "#{read} has no deadline inside its thread"
      assert_operator left, :<=, Solana::Deadline::WEB
    end
  end

  test "a long-budget action runs as its named block, and an ordinary one does not" do
    log_in_as(@user)
    names = []
    real = Solana::Deadline.method(:long_budget)
    spy = ->(name, &block) { names << name; real.call(name, &block) }

    Solana::Deadline.stub :long_budget, spy do
      post discard_prepared_entry_contest_path(@contest), as: :json
      assert_empty names, "CONTROL: an action off the list"
      post recover_pending_entry_contest_path(@contest), as: :json
    end

    assert_equal [:entry_recovery], names
  end

  test "every long-budget action is a route" do
    Solana::Deadline::LONG_BUDGET_ACTIONS.each_key do |key|
      controller, action = key.split("#")
      assert Rails.application.routes.routes.any? { |r| r.defaults[:controller] == controller && r.defaults[:action] == action }, key
    end
  end

  test "all three base controllers answer Exceeded themselves" do
    [ApplicationController, Api::V1::BaseController, McpController].each do |klass|
      handler = klass.rescue_handlers.reverse.find { |name, _| Solana::Deadline::Exceeded <= name.constantize }
      assert_equal ["Solana::Deadline::Exceeded", :render_rpc_deadline], handler, klass.name
    end
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
