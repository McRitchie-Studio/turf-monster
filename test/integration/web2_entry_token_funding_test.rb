require "test_helper"

# Web2 entry-token funding — the ONE audience the funds wall still sends to an
# ENTRY TOKEN (the Buy an Entry Token modal: Coinflow buy-1 on top, the Stripe pack
# picker below) rather than to the Get USDC card.
#
# THAT AUDIENCE IS NOT "web2", and an earlier version of this header said it was.
# showFundsNeeded stopped forking on session.mode on 2026-09-05: the answer at the
# funds wall is Get USDC for everyone EXCEPT the USDC kill-switch audience (a web2
# viewer with ENABLE_WEB2_USDC_ENTRY off), who literally cannot pay an entry with
# USDC. Top Up Wallet is not on either branch — see the note above the dispatcher
# tests below.
#
# The split is a single client dispatcher, selectionBoard#showFundsNeeded, that
# every funds-needed reroute (the no_funding blocker, the hold-window check, the
# chain-layer "no entry token" twin) funnels through. These assert the wiring at
# the render boundary — the modal registration, both rails, and the dispatcher. The
# live Alpine handoff is a tracked Playwright e2e gap (same precedent as
# wallet_topup_test + the on-chain success modal). Companion to
# wallet_topup_test.rb.
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

  # --- the funds dispatcher: kill-switch audience -> buy-entry-token, everyone
  #     else -> buy-usdc. Nothing routes to wallet-topup any more. ---

  test "showFundsNeeded sends the funds wall to Get USDC, keeping only the kill-switch audience on tokens" do
    get contest_path(contests(:one))
    assert_response :success
    body = response.body
    assert_includes body, "showFundsNeeded() {"
    # REBOUND (2026-09-05). The old assertion pinned `mode === 'web2'` as the
    # whole condition — the fork that sent every web2 player to a modal with no
    # visible rails in production. What must hold now: the USDC card is the
    # default answer, and the ONLY audience still routed to tokens is the one
    # that literally cannot pay with USDC (ENABLE_WEB2_USDC_ENTRY off).
    assert_includes body, "session.mode === 'web2' && !session.web2UsdcEntry"
    assert_includes body, "this.showBuyEntryToken();"
    assert_includes body, "this.showGetUsdc();"
    # showBuyEntryToken must refuse to open with no rail to show, rather than
    # painting "pick how to pay" over an empty box.
    assert_includes body, "if (!Alpine.store('session').entryTokenRailsAvailable) {"
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
    # showFundsNeeded's own body calls showBuyEntryToken / showGetUsdc, not
    # itself, so it never inflates the count.
    assert_equal 3, body.scan("this.showFundsNeeded();").size,
                 "all three funds-needed reroutes must funnel through showFundsNeeded"
  end

  # --- WHY NOTHING HERE ASSERTS A ROUTE INTO TOP UP WALLET ---------------------
  #
  # A test named "Top Up Wallet is still REACHABLE, not merely still defined" used
  # to sit here, and it was WORSE than no test. It asserted, against the whole
  # contest page:
  #
  #     $store.modals.swap('wallet-topup', {})   # "the Get USDC card must carry
  #                                              #  the onward control into Top Up
  #                                              #  Wallet"
  #     "Buy USDC with Coinbase"
  #
  # NEITHER STRING COMES FROM THE GET USDC CARD. The swap() literal is rendered by
  # modals/_onramp_hub (its Back link) and the Coinbase title by
  # modals/_wallet_topup, and the layout registers BOTH ungated into every contest
  # page — so these held whatever the card did.
  #
  # (Since /tasks/kill-switch-leaves-dead-buttons the Coinbase title is no longer
  # among them on THIS page: _wallet_topup gates that rail on
  # cdp_ramp_modal_available?, which reads logged_in? as well as ENABLE_CDP_RAMP,
  # and the render above is a guest. The layout still registers the modal ungated
  # — only its Coinbase rail moved behind the guard. That strengthens the case for
  # deleting this test rather than weakening it: the string was never the card's
  # to begin with, and now it is not even reliably on the page.) It also asserted
  # `showWalletTopup() {` and the layout's own `current().id === 'wallet-topup'`,
  # which are the board script and the layout answering for a third file again.
  #
  # Measured three ways, 2026-09-07:
  #
  #   · commit 6e4d73cd ADDED that control to the card (as its :198 "More ways to
  #     add funds" button) and b792cd32 REMOVED it. Every assertion in this test
  #     was byte-identical and green across both.
  #   · replacing modals/_buy_usdc.html.erb with an empty <div> — the entire card
  #     deleted — left this file and wallet_topup_test.rb at 26 runs, 170
  #     assertions, 0 failures.
  #   · re-adding the control failed test/views/buy_usdc_modal_test.rb at its
  #     wallet-topup refutation, and moved nothing here.
  #
  # AND THE FAILURE MESSAGE POINTED THE WRONG WAY, which is the part that made it
  # urgent rather than merely useless. The CDP/Coinbase onramp has NO LEGAL
  # CLEARANCE (operator, 2026-09-06), so the card deliberately carries no route to
  # it — direct or one hop away through Top Up Wallet. Had this ever gone red it
  # would have instructed the next builder to restore exactly that route.
  #
  # WHERE THE COVERAGE ACTUALLY LIVES, and it is the opposite assertion:
  #   · test/views/buy_usdc_modal_test.rb, "the card offers Phantom and NOTHING
  #     resembling a payment rail" — renders the PARTIAL alone (so the layout's
  #     other modals cannot answer for it) and refutes cdp-ramp, wallet-topup,
  #     onramp-hub and "Coinbase". That guard is what fails if the link returns.
  #   · the dispatcher tests above pin the route that IS live: showFundsNeeded ->
  #     showGetUsdc.
  #   · wallet_topup_test.rb pins that the wallet-topup modal is still registered.
  #
  # showWalletTopup itself now has ZERO callers. That orphan is a known, escalated
  # loose end (see the closing comment in modals/_buy_usdc.html.erb): what to do
  # with Top Up Wallet and the Add Funds hub while the onramp is uncleared is an
  # operator decision about those surfaces, not something a test may quietly
  # decide by demanding a link back.

  # --- the empty-rails guard, with its FALSE branch actually run --------------
  #
  # Review found this guard had never executed. entryTokenRailsAvailable mirrors
  # the only two rails _buy_entry_token renders, but onramp_helper.rb opens
  # `return true unless Rails.env.production?`, so outside production every rail
  # is visible and the flag can only ever be true. The assertion that existed was
  # an assert_includes of the literal `if` line — it proved the branch was WRITTEN,
  # not that it works.
  #
  # Fake production the way the onramp helper's own tests do, turn both rails off,
  # and read the server's answer out of the payload the board branches on.
  # (The JS branch itself still wants an e2e; this closes the server half, which
  # is the half that decides.)
  def in_production(&block) = Rails.env.stub(:production?, true, &block)

  def session_context_flag(body, key)
    json = body[/<script type="application\/json" id="session-context">(.*?)<\/script>/m, 1]
    JSON.parse(json).fetch(key)
  end

  test "entryTokenRailsAvailable goes FALSE when neither entry-token rail is visible" do
    with_env("ENABLE_COINFLOW" => nil, "PAYMENT_PROVIDER" => nil) do
      in_production do
        get contest_path(contests(:one))
        assert_response :success
        refute session_context_flag(response.body, "entryTokenRailsAvailable"),
               "with Coinflow unset and Stripe not the provider, the entry-token " \
               "modal has no rail to show — the flag must say so, or showBuyEntryToken " \
               "opens 'pick how to pay' over an empty box (prod, 2026-09-05)"
      end
    end
  end

  test "and TRUE as soon as one rail comes back" do
    with_env("ENABLE_COINFLOW" => "true", "PAYMENT_PROVIDER" => nil) do
      in_production do
        get contest_path(contests(:one))
        assert_response :success
        assert session_context_flag(response.body, "entryTokenRailsAvailable"),
               "one visible rail is enough to keep the entry-token modal open-able"
      end
    end
  end

  def with_env(pairs)
    originals = pairs.keys.to_h { |k| [k, ENV[k]] }
    pairs.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
    yield
  ensure
    originals.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
