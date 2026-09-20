require "test_helper"

# [integration] The DELIVERED callback document — the page a wallet really
# returns to, fetched over the real router and layout.
#
# WHAT THIS TIER OWNS. The unit and component tiers drive what the
# contest_entry partial EMITS. Neither can see the one arrangement that makes the
# redirect transport work at all: that this app's partial and studio-engine's
# callback view arrive in the SAME document, in the right ORDER, on the route a
# wallet is handed as redirect_link. That composition spans a gem boundary, and
# this repo's Gemfile records several rounds of it failing silently.
#
# THIS FILE WAS phantom_callback_redirect_link_test.rb UNTIL 2026-09-20, and the
# rename is the honest part of /tasks/retire-wallet-resume-wrapper. It used to
# own two things: the ORDER below, and a turf-side `walletOps.resume` wrapper that
# defaulted the signing hop's `redirect_link` because neither studio-engine nor
# solana-studio supplied one. solana-studio 0.9.3 journals `redirectLink` in
# `beginConnect`, the Gemfile floor is now `>= 0.12.0`, and the wrapper is
# deleted — so its three wrapper assertions and its retirement trigger went with
# it. What remains has nothing to do with `redirect_link`, and the name said
# otherwise. §7 of docs/WALLET_TRANSPORT_ARCHITECTURE.md carries the full record.
#
# WHAT REMAINS IS NOT A LEFTOVER. The ordering guard is load-bearing for a
# DIFFERENT defect, and the sharper of the two: `walletOps.resume()` consumes the
# journal at `take()` BEFORE the signTransaction hop reaches `requireHandler`, so
# an intent that is not registered on this document loses the entry with nothing
# left to retry — the user approves in their wallet, comes back, and the entry is
# silently gone. That is the blocker the partial's own header describes, and it is
# why the partial renders from layouts/application on EVERY page.
#
# ORDER MEANS TWO COMPARISONS, NOT ONE, and for a while this file only made the
# first. `wallet_ops.js` must load before the registration (or there is no
# `walletOps.define` to call) AND the registration must land before studio-engine's
# callback script CALLS `resume` (or the journal is consumed with no handler to
# answer it). Only the first was asserted, so moving the host partial below the
# engine's `yield` kept the old assertions green while restoring the defect in
# full. Raised in review of PR #673; both comparisons are made below, and they are
# now anchored on the REGISTRATION rather than on the retired wrapper's flag,
# which is what they were always really about.
class PhantomCallbackIntentRegistrationTest < ActionDispatch::IntegrationTest
  # The exact route the board hands Phantom as redirect_link
  # (app/views/contests/_turf_totals_board.html.erb).
  CALLBACK = "/auth/phantom/callback".freeze

  # ANCHORED ON THE REGISTRATION CALL ITSELF, not on a loose "contest_entry":
  # the delivered document names that intent in prose comments and in the
  # handlers too, and an index on the loose string finds the first comment and
  # compares the wrong coordinate.
  REGISTRATION = "S.walletOps.define('contest_entry'".freeze

  setup do
    get CALLBACK
    assert_response :success, "the route a wallet is told to return to must render for an anonymous visitor"
    @body = response.body
  end

  test "the callback document registers the intent, after the script that holds the registry" do
    ops_at = @body.index("solana_studio/wallet_ops")
    registration_at = @body.index(REGISTRATION)

    assert ops_at, "the callback document no longer loads solana_studio/wallet_ops.js"
    assert registration_at,
           "the callback document does not register the contest_entry intent — walletOps.resume " \
           "consumes the journal before requireHandler, so the signing hop returns to a page that " \
           "cannot finish the entry, and the entry is lost with nothing to retry"
    assert ops_at < registration_at,
           "wallet_ops.js must load BEFORE the registration, or there is no walletOps.define to call " \
           "and the partial's own guard returns early — registering nothing, silently"
  end

  test "the intent registers BEFORE the engine's callback script calls resume" do
    # THE SECOND COMPARISON, and the one the header's claim actually rests on.
    # studio-engine's phantom_callback view dispatches from a bare inline script
    # during body parse — `studio.walletOps.resume(params, {...})` — so a host
    # partial rendered below its `yield` would register the handler AFTER the call
    # that needs it. The first comparison stays green through that move; this one
    # does not.
    #
    # ANCHORED ON THE ENGINE'S OWN TEXT, not on a bare "walletOps.resume": this
    # app's partial mentions `walletOps.resume()` in its own header comment, and
    # that comment is delivered too — an index on the loose string finds the
    # comment at the top of the document and the comparison passes vacuously.
    registration_at = @body.index(REGISTRATION)
    engine_call_at = @body.index("studio.walletOps.resume(params")

    assert engine_call_at,
           "studio-engine's callback no longer dispatches through walletOps.resume(params, …). " \
           "If it now dispatches some other way, this comparison is measuring nothing: re-anchor it " \
           "on whatever the engine calls, and do not simply delete it — the registration must still " \
           "land before the journal is consumed"
    assert registration_at, "the callback document does not register the contest_entry intent"
    assert registration_at < engine_call_at,
           "the contest_entry intent registers AFTER the engine already called resume — the journal " \
           "is consumed at take() before requireHandler, so the entry is lost after the user has " \
           "already approved it. The host partial must render ABOVE the engine's yield."
  end

  test "the intent's handlers reach this document too" do
    # Registration names the handlers; these are the functions it names. The
    # registration landing in time is worth nothing if the functions it points at
    # are on another document, and losing either loses the entry after the user
    # has already approved it.
    assert_includes @body, "tmCompleteContestEntry"
    assert_includes @body, "contest_entry"
  end
end
