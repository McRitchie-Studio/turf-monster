require "test_helper"

# [integration] The DELIVERED callback document — the page a wallet really
# returns to, fetched over the real router and layout.
#
# WHAT THIS TIER OWNS. The unit test drives the wrapper; the component test runs
# what the partial emits. Neither can see the ONE arrangement that makes the
# wrapper work at all: that this app's partial and studio-engine's callback view
# arrive in the SAME document, in the right ORDER, on the route a wallet is
# handed as redirect_link. That composition spans a gem boundary, and this repo's
# Gemfile records several rounds of it failing silently.
#
# ORDER MEANS TWO COMPARISONS, NOT ONE, and for a while this file only made the
# first. `wallet_ops.js` must load before the wrapper (or there is no `resume` to
# wrap) AND the wrapper must install before studio-engine's callback script CALLS
# `resume` (or the call goes out unwrapped and hop two loses its redirect_link).
# Only the first was asserted, so moving the host partial below the engine's
# `yield` kept both old assertions green while restoring the defect in full.
# Raised in review of PR #673.
class PhantomCallbackRedirectLinkTest < ActionDispatch::IntegrationTest
  # The exact route the board hands Phantom as redirect_link
  # (app/views/contests/_turf_totals_board.html.erb).
  CALLBACK = "/auth/phantom/callback".freeze

  setup do
    get CALLBACK
    assert_response :success, "the route a wallet is told to return to must render for an anonymous visitor"
    @body = response.body
  end

  test "the callback document carries the resume wrapper, after the script it wraps" do
    ops_at = @body.index("solana_studio/wallet_ops")
    wrapper_at = @body.index("tmRedirectLinkDefaulted")

    assert ops_at, "the callback document no longer loads solana_studio/wallet_ops.js"
    assert wrapper_at, "the callback document does not carry the redirect_link default — " \
                       "the signing hop will go out with no redirect_link and the wallet " \
                       "will have nowhere to return the signed bytes"
    assert ops_at < wrapper_at,
           "wallet_ops.js must load BEFORE the wrapper, or there is no resume to wrap"
  end

  test "the wrapper installs BEFORE the engine's callback script calls resume" do
    # THE SECOND COMPARISON, and the one the header's claim actually rests on.
    # studio-engine's phantom_callback view dispatches from a bare inline script
    # during body parse — `studio.walletOps.resume(params, {...})` — so a host
    # partial rendered below its `yield` would install the default AFTER the call
    # it exists to fix. Both assertions above stay green through that move; this
    # one does not.
    #
    # ANCHORED ON THE ENGINE'S OWN TEXT, not on a bare "walletOps.resume": this
    # app's partial mentions `walletOps.resume()` in its own header comment, and
    # that comment is delivered too — an index on the loose string finds the
    # comment at the top of the document and the comparison passes vacuously.
    wrapper_at = @body.index("tmRedirectLinkDefaulted")
    engine_call_at = @body.index("studio.walletOps.resume(params")

    assert engine_call_at,
           "studio-engine's callback no longer dispatches through walletOps.resume(params, …) — " \
           "if it now passes its own redirect_link, this whole wrapper is retirable: delete it " \
           "from app/views/shared/_contest_entry_intent.html.erb and this file with it"
    assert wrapper_at < engine_call_at,
           "the redirect_link default installs AFTER the engine already called resume — " \
           "hop two goes out with no redirect_link and the wallet has nowhere to answer. " \
           "The host partial must render ABOVE the engine's yield."
  end

  test "the intent's handlers reach this document too" do
    # The wrapper fixes the OUTBOUND leg of hop two. The handlers are what
    # finishes hop two's RETURN, on this same page, and losing either loses the
    # entry after the user has already approved it.
    assert_includes @body, "tmCompleteContestEntry"
    assert_includes @body, "contest_entry"
  end

  # ── THE RETIREMENT TRIGGER ────────────────────────────────────────────────
  test "studio-engine still calls resume without a redirect link" do
    # DERIVED FROM THE SHIPPED GEM, in the delivered document, rather than
    # trusted from a comment. The wrapper exists for exactly one reason:
    # studio-engine's solana_sessions/phantom_callback calls
    #
    #     studio.walletOps.resume(params, { navigate: function(url) { … } })
    #
    # and passes no redirectLink, while solana-studio's beginConnect journals
    # none either — so walletOps' `opts.redirectLink || journal.redirectLink`
    # resolves to undefined and the parameter is dropped from the deeplink.
    #
    # WHEN THIS GOES RED it is almost certainly GOOD NEWS: the gem started
    # supplying its own. The wrapper is written as a default rather than an
    # override, so nothing breaks the moment that happens — but it becomes dead
    # weight, and dead weight in a wallet path is how the next reader loses an
    # hour. Delete the wrapper block in
    # app/views/shared/_contest_entry_intent.html.erb, delete this test, and
    # raise the solana-studio / studio-engine floor that made it unnecessary.
    call = @body[/walletOps\.resume\s*\(\s*params\s*,\s*\{[^}]*\}/m]
    assert call, "could not find studio-engine's walletOps.resume call in the callback document"

    refute_match(/redirectLink/, call,
                 "studio-engine now passes its own redirectLink to walletOps.resume — " \
                 "retire the wrapper in app/views/shared/_contest_entry_intent.html.erb " \
                 "and the floor note that goes with it")
  end
end
