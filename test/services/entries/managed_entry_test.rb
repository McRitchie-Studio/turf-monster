require "test_helper"

# [unit] Entries::ManagedEntry: the gate-then-spend-then-confirm path the
# browser's #enter and the agent API both run. The browser's contract is held
# by test/controllers/contests_enter_characterization_test.rb; this file holds
# what the API reads off the service: which rule refused (Entry::Refusal#code),
# whether a spend was attempted, and that an entry built inside the lock does
# not outlive a failure.
class Entries::ManagedEntryTest < ActiveSupport::TestCase
  include AgentApiTestSupport

  setup do
    @contest = make_onchain!(contests(:one))
    @user = make_managed!(users(:sam))
    @vault = LedgerVault.new(tokens: [{ pda: "token-1", consumed: false }], usdc: 100.0)
  end

  def cart(matchups = fixture_matchups, user: @user)
    entry = @contest.entries.create!(user: user, status: :cart)
    matchups.each { |matchup| entry.selections.create!(slate_matchup: matchup) }
    entry
  end

  def service(usdc_allowed: false)
    Entries::ManagedEntry.new(contest: @contest, user: @user, usdc_allowed: usdc_allowed)
  end

  def refusal(managed = service, entry = cart)
    on_chain(@vault) { assert_raises(Entry::Refusal) { managed.call(entry) } }
  end

  test "a refusal is a RuntimeError carrying the old message, so the browser path reads as before" do
    @contest.update!(status: :settled)
    error = refusal

    assert_kind_of RuntimeError, error
    assert_equal "Contest is not open", error.message
    assert_equal :contest_not_open, error.code
  end

  test "each gate refuses with its own code before anything is spent" do
    cases = {
      contest_not_open: -> { @contest.update!(status: :settled) },
      contest_locked: -> { @contest.update!(starts_at: 1.minute.ago) },
      contest_full: lambda {
        @contest.update!(max_entries: 1)
        enter!(users(:jordan), @contest, fixture_matchups)
      },
      entry_limit_reached: lambda {
        g, h = extra_matchups
        [fixture_matchups.first(5) + [g], fixture_matchups.first(5) + [h], fixture_matchups.last(5) + [g]].each do |lineup|
          enter!(@user, @contest, lineup)
        end
      },
      duplicate_lineup: -> { enter!(@user, @contest, fixture_matchups) }
    }

    cases.each do |code, arrange|
      ActiveRecord::Base.transaction(requires_new: true) do
        arrange.call
        managed = service
        assert_equal code, refusal(managed).code
        assert_not managed.spend_attempted?, "#{code} must refuse before the spend"
        raise ActiveRecord::Rollback
      end
    end
    assert_empty @vault.tickets
    assert_empty @vault.spent_tokens
  end

  test "too few picks and a team whose game has started are refused before the spend" do
    short = service
    assert_equal :invalid_picks, refusal(short, cart(fixture_matchups.first(5))).code
    assert_not short.spend_attempted?

    Entry.where(contest: @contest).destroy_all
    game = Game.create!(home_team_slug: "team-a", away_team_slug: "team-b", kickoff_at: 1.hour.ago)
    slate_matchups(:m1).update!(game_slug: game.slug)
    started = service
    error = refusal(started)
    assert_equal :team_locked, error.code
    assert_match(/Team A's game has already started/, error.message)
    assert_not started.spend_attempted?
    assert_empty @vault.tickets
  end

  test "funding: a token is spent first, and USDC is left alone" do
    managed = service(usdc_allowed: true)
    outcome = on_chain(@vault) { managed.call(cart) }

    assert_equal ["token", true], [outcome.funding_method, outcome.token_consumed]
    assert managed.spend_attempted?
    assert outcome.entry.active?
    assert_equal 100.0, @vault.usdc_balance
  end

  test "the spend runs under the gem's full wait budget, not the request's" do
    budgets = []
    @vault.define_singleton_method(:enter_contest_with_token) do |*args, **opts|
      budgets << Thread.current[Solana::Client::WAIT_BUDGET_KEY]
      super(*args, **opts)
    end
    Solana::Client.with_wait_budget(SolanaWaitBudget::REQUEST) { on_chain(@vault) { service.call(cart) } }

    assert_equal [Solana::Client::DEFAULT_WAIT_BUDGET], budgets
  end

  test "funding: no token and USDC not allowed refuses no_entry_token with funded USDC untouched" do
    @vault = LedgerVault.new(tokens: [], usdc: 100.0)
    managed = service(usdc_allowed: false)

    error = refusal(managed)

    assert_equal :no_entry_token, error.code
    assert_equal "No entry tokens. Buy at /tokens/buy", error.message
    assert_not managed.spend_attempted?
    assert_equal 100.0, @vault.usdc_balance
    assert_empty @vault.balance_calls
  end

  test "funding: no token and USDC allowed pays in USDC" do
    @vault = LedgerVault.new(tokens: [], usdc: 100.0)
    outcome = on_chain(@vault) { service(usdc_allowed: true).call(cart) }

    assert_equal ["usdc", false], [outcome.funding_method, outcome.token_consumed]
    assert_in_delta 81.0, @vault.usdc_balance
  end

  test "funding: confirmed-short USDC refuses insufficient_funds before the spend" do
    @vault = LedgerVault.new(tokens: [], usdc: 1.0)
    managed = service(usdc_allowed: true)

    assert_equal :insufficient_funds, refusal(managed).code
    assert_not managed.spend_attempted?
  end

  test "funding: an account with no managed wallet refuses wallet_not_server_signable" do
    @user.update!(web2_solana_address: nil, web3_solana_address: "foUuRyeibadQoGdKXZ9pBGDqmkb1jY1jYsu8dZ29nds")
    managed = service

    assert_equal :wallet_not_server_signable, refusal(managed).code
    assert_not managed.spend_attempted?
  end

  test "spend_attempted? is true once the chain call is made, even when it fails" do
    @vault.fail_next_enter = :unlanded
    managed = service
    entry = cart

    on_chain(@vault) { assert_raises(Solana::Client::RpcError) { managed.call(entry) } }

    assert managed.spend_attempted?
    assert entry.reload.cart?
    assert_nil entry.onchain_tx_signature
  end

  test "an entry built in the block exists only if the spend commits" do
    @vault.fail_next_enter = :rejected
    build = lambda do
      entry = @contest.entries.create!(user: @user, status: :cart)
      fixture_matchups.each { |matchup| entry.selections.create!(slate_matchup: matchup) }
      entry
    end

    assert_no_difference ["Entry.count", "Selection.count"] do
      on_chain(@vault) { assert_raises(Solana::Client::RpcError) { service.call(&build) } }
    end

    outcome = nil
    assert_difference "Entry.count", 1 do
      outcome = on_chain(@vault) { service.call(&build) }
    end
    assert outcome.entry.active?
    assert_equal @vault.tickets.sole[:signature], outcome.entry.onchain_tx_signature
  end
end
