require "test_helper"

# Web2 entry-token funding — a web2 / managed player who lacks funds at the entry
# blocker now buys an ENTRY TOKEN (the Buy an Entry Token modal: Coinflow buy-1 on
# top, the Stripe pack picker below) instead of the USDC Top Up Wallet. Web3 wallet
# players are UNCHANGED (still the Coinbase-forward USDC Top Up Wallet).
#
# The audience split is a single client dispatcher, selectionBoard#showFundsNeeded,
# that every funds-needed reroute (the no_funding blocker, the hold-window check,
# the chain-layer "no entry token" twin) funnels through. These assert the wiring
# at the render boundary — the modal registration, both rails, the dispatcher, and
# that web3's showWalletTopup path is intact. The live Alpine handoff is a tracked
# Playwright e2e gap (same precedent as wallet_topup_test + the on-chain success
# modal). Companion to wallet_topup_test.rb.
class Web2EntryTokenFundingTest < ActionDispatch::IntegrationTest
  # --- modal registration (ungated, like wallet-topup / onramp-hub) ---

  test "the buy-entry-token modal is registered ungated in the layout for a guest" do
    get contests_path
    assert_response :success
    assert_includes response.body, "$store.modals.current().id === 'buy-entry-token'",
                     "buy-entry-token must be registered in the layout (ungated, like wallet-topup)"
    assert_includes response.body, "Buy an Entry Token"
  end

  test "the buy-entry-token modal stays registered when logged in as a web2 user" do
    log_in_as users(:jordan)
    get contests_path
    assert_response :success
    assert_includes response.body, "$store.modals.current().id === 'buy-entry-token'"
    assert_includes response.body, "Buy an Entry Token"
    # A magic-link login is a web2 session — the audience this modal serves.
    assert_includes response.body, %("mode":"web2")
  end

  # --- the two stacked rails: Coinflow on top, Stripe below ---

  test "the modal renders the Coinflow buy-1 rail wired to tmCoinflowBuyOne('single')" do
    get contests_path
    assert_response :success
    body = response.body
    assert_includes body, %(data-buy-rail="coinflow")
    assert_includes body, "tmCoinflowBuyOne('single')"
    # 1 token = 1 entry framing + the modal's own subtitle.
    assert_includes body, "pick how to pay"
    # The Coinflow kickoff script is present so the button works.
    assert_includes body, "window.tmCoinflowBuyOne = async function"
  end

  test "the modal renders the Stripe pack-picker rail, swapping into the auth wizard" do
    get contests_path
    assert_response :success
    body = response.body
    assert_includes body, %(data-buy-rail="stripe")
    assert_includes body,
                    "$store.modals.swap('auth', { step: 'tokens-picker', mintedCount: 0, mintedBalance: 0, errorText: '', redirectUrl: '', txSignature: '' })"
  end

  test "the Coinflow rail renders ABOVE the Stripe rail (link on top, button below)" do
    get contests_path
    assert_response :success
    body = response.body
    coinflow_at = body.index(%(data-buy-rail="coinflow"))
    stripe_at   = body.index(%(data-buy-rail="stripe"))
    assert coinflow_at, "the Coinflow rail must render"
    assert stripe_at,   "the Stripe rail must render"
    assert coinflow_at < stripe_at,
           "the Coinflow rail must render above the Stripe rail (Coinflow first)"
  end

  # --- the audience dispatcher: web2 -> buy-entry-token, web3 -> wallet-topup ---

  test "showFundsNeeded splits web2 to the Buy an Entry Token modal and web3 to Top Up Wallet" do
    get contest_path(contests(:one))
    assert_response :success
    body = response.body
    assert_includes body, "showFundsNeeded() {"
    assert_includes body, "if (Alpine.store('session').mode === 'web2') {"
    assert_includes body, "this.showBuyEntryToken();"
    assert_includes body, "this.showWalletTopup();"
    # showBuyEntryToken opens the buy-entry-token modal (open vs swap, like wallet-topup).
    assert_includes body, "showBuyEntryToken() {"
    assert_includes body, "s.open('buy-entry-token', { enterAnim: 'shake' })"
    assert_includes body, "s.swap('buy-entry-token', {})"
  end

  test "every funds-needed reroute funnels through showFundsNeeded" do
    get contest_path(contests(:one))
    assert_response :success
    body = response.body
    # The no_funding eligibility-blocker case routes through the dispatcher.
    assert_match(/case 'no_funding':\s+this\.showFundsNeeded\(\);/, body,
                 "the no_funding entry wall must route through showFundsNeeded")
    # Exactly the three funds-needed reroutes call the dispatcher (the no_funding
    # blocker, the hold-window fundable:false abort, and the chain-layer twin).
    # showFundsNeeded's own body calls showBuyEntryToken / showWalletTopup, not
    # itself, so it never inflates the count.
    assert_equal 3, body.scan("this.showFundsNeeded();").size,
                 "all three funds-needed reroutes must funnel through showFundsNeeded"
  end

  # --- web3 unchanged: showWalletTopup + the USDC Top Up Wallet are intact ---

  test "web3's showWalletTopup and the USDC Top Up Wallet modal are unchanged" do
    get contest_path(contests(:one))
    assert_response :success
    body = response.body
    assert_includes body, "showWalletTopup() {"
    assert_includes body, "s.open('wallet-topup', { enterAnim: 'shake' })"
    assert_includes body, "$store.modals.current().id === 'wallet-topup'"
    assert_includes body, "Buy USDC with Coinbase"
  end
end
