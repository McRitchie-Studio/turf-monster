require "test_helper"

# Render-gating coverage for the COINBASE-FORWARD Top Up Wallet modal
# (modals/_wallet_topup), its ungated registration in the application layout,
# the entry-blocker re-route in contests/_turf_totals_board, and the Add Funds
# hub's returnModal back-branching. Companion to onramp_hub_test.rb.
#
# Since unified funding (operator 2026-06-13), a web2/managed USDC entry works
# (server-signed enter_contest) when ENABLE_WEB2_USDC_ENTRY is on, so USDC is the
# cash funding rail again: the primary CTA buys USDC with Coinbase and there are
# NO entry-token links in the default arrangement. The flag-off kill-switch
# degrades — client-side — to the entry-token rail for web2 viewers who can't pay
# with USDC. That branching is Alpine-runtime (tokenFallback reads $store.session),
# so it's asserted at the render level via the gating expressions only; the live
# modal handoff is a tracked Playwright e2e gap (mirrors the on-chain
# success-modal coverage-gap precedent).
class WalletTopupTest < ActionDispatch::IntegrationTest
  # --- modal registration (ungated, like onramp-hub) ---

  test "the wallet-topup modal is registered ungated in the layout for a guest" do
    get contests_path
    assert_response :success
    assert_includes response.body, "$store.modals.current().id === 'wallet-topup'",
                     "wallet-topup must be registered in the layout (ungated, like onramp-hub)"
    assert_includes response.body, "Top Up Wallet"
  end

  test "the wallet-topup modal stays registered when logged in" do
    log_in_as users(:jordan)
    get contests_path
    assert_response :success
    assert_includes response.body, "$store.modals.current().id === 'wallet-topup'"
    assert_includes response.body, "Top Up Wallet"
  end

  # --- header: USDC balance (the funding currency) ---

  test "the header shows the USDC balance, not a hardcoded token count" do
    get contests_path
    assert_response :success
    # USDC is the funding currency again, so the default header surfaces the USDC
    # balance (em-dash when the navbar cache is cold) from $store.session.usdcCents.
    assert_includes response.body, "USDC balance:"
    assert_includes response.body, "get usdcDisplay()"
    assert_includes response.body, "$store.session.usdcCents"
    # The token-count header survives ONLY as the flag-off (tokenFallback) degrade,
    # gated behind x-show, not the default line.
    assert_includes response.body, %(x-show="tokenFallback")
  end

  # --- primary CTA: Buy USDC with Coinbase (cdp-ramp buy preflight) ---

  test "the primary CTA buys USDC with Coinbase via the cdp-ramp buy preflight" do
    get contests_path
    assert_response :success
    body = response.body
    # Coinbase-forward: the bordered primary CTA hands off to the existing
    # cdp-ramp buy preflight (the same handoff /wallet Buy USDC + the hub use).
    assert_includes body, %(data-topup-rail="coinbase")
    assert_includes body, "Buy USDC with Coinbase"
    assert_includes body,
                     "$store.modals.swap('cdp-ramp', { flow: 'buy', step: 'preflight' })"
    # The Coinbase pitch is hidden for the web2 kill-switch audience that can't
    # pay with USDC.
    assert_match(%r{x-if="!tokenFallback">\s*<button\b[^>]*data-topup-rail="coinbase"}m, body,
                 "the Coinbase CTA must be gated behind !tokenFallback")
  end

  # --- flag-aware degrade: web2 + ENABLE_WEB2_USDC_ENTRY off -> token rail ---

  test "the token rail is the kill-switch degrade, gated behind tokenFallback" do
    get contests_path
    assert_response :success
    body = response.body
    # The entry-token CTA exists ONLY inside the tokenFallback branch (web2 +
    # flag off); it is NOT the default primary action.
    assert_includes body, %(data-topup-rail="tokens")
    assert_includes body, "Buy Entry Tokens"
    assert_match(%r{x-if="tokenFallback">\s*<button\b[^>]*data-topup-rail="tokens"}m, body,
                 "the token rail must be gated behind tokenFallback")
    # tokenFallback fires for web2 viewers ONLY when the web2-USDC kill-switch is
    # off — web3 and flag-on web2 always see the Coinbase pitch.
    assert_includes body,
                    "get tokenFallback() { return $store.session.mode === 'web2' && !$store.session.web2UsdcEntry }"
  end

  test "ENABLE_WEB2_USDC_ENTRY off emits web2UsdcEntry false so a web2 viewer degrades" do
    log_in_as users(:jordan)
    AppFlags.stub :web2_usdc_entry?, false do
      get contest_path(contests(:one))
    end
    assert_response :success
    body = response.body
    # The session payload (Carl's wiring) carries the kill-switch state the
    # modal's tokenFallback getter reads. A logged-in managed user is web2 mode,
    # so with the flag off this viewer flips to the entry-token rail.
    assert_includes body, %("web2UsdcEntry":false),
                    "flag-off must emit web2UsdcEntry:false into #session-context"
    assert_includes body, %("mode":"web2"),
                    "a magic-link login is a web2 session"
  end

  test "ENABLE_WEB2_USDC_ENTRY on (default) emits web2UsdcEntry true" do
    log_in_as users(:jordan)
    AppFlags.stub :web2_usdc_entry?, true do
      get contest_path(contests(:one))
    end
    assert_response :success
    assert_includes response.body, %("web2UsdcEntry":true),
                    "flag-on must emit web2UsdcEntry:true so web2 sees the Coinbase pitch"
  end

  # --- quiet secondary: the Add Funds hub ---

  test "the quiet link opens the hub flagged as opened-from wallet-topup" do
    get contests_path
    assert_response :success
    assert_includes response.body, "More ways to add funds"
    assert_includes response.body,
                     "$store.modals.swap('onramp-hub', { returnModal: 'wallet-topup' })"
  end

  # --- hub returnModal back-branching (unchanged) ---

  test "the hub Back link routes by returnModal, differing for wallet-topup vs the picker" do
    get contests_path
    assert_response :success
    body = response.body
    # When opened from wallet-topup, Back slides back to the Top Up Wallet modal.
    assert_includes body,
                    "props.returnModal === 'wallet-topup' ? $store.modals.swap('wallet-topup', {})",
                    "hub Back must return to wallet-topup when opened from there"
    # Otherwise (the existing tokens-picker path) Back returns to the picker —
    # the unchanged default that keeps the _tokens / _paypal_tokens link working.
    assert_includes body,
                    "$store.modals.swap('auth', { step: (props.returnStep || 'tokens-picker') })",
                    "hub Back must default to the tokens picker"
  end

  # --- entry-blocker re-route (render level; e2e gap noted above) ---

  test "the board entry blocker routes the funds-needed wall through showFundsNeeded (web3 keeps Top Up Wallet)" do
    get contest_path(contests(:one))
    assert_response :success
    body = response.body
    # web3's showWalletTopup method still exists and still opens the USDC Top Up
    # Wallet — the web3 branch of the dispatcher is byte-identical to before.
    assert_includes body, "showWalletTopup()"
    assert_includes body, "s.open('wallet-topup', { enterAnim: 'shake' })"
    # The 'no_funding' eligibility-blocker case (renamed from 'no_tokens' in the
    # unified-funding refactor) now routes through the audience dispatcher:
    # web2 → Buy an Entry Token modal, web3 → Top Up Wallet.
    assert_match(/case 'no_funding':\s+this\.showFundsNeeded\(\);/, body,
                 "the no_funding entry wall must route through showFundsNeeded")
    assert_includes body, "if (Alpine.store('session').mode === 'web2') {"
    refute_match(/case 'no_tokens':/, body,
                 "the legacy no_tokens blocker case must be gone (renamed no_funding)")
  end

  test "the board keeps showTokensPanel for the post-signup pack-picker resume" do
    get contest_path(contests(:one))
    assert_response :success
    body = response.body
    # showTokensPanel stays intact (the picker, reached via the hub's Stripe
    # card + the post-signup pendingAuthStep resume), so the deferred buy-tokens
    # step is unchanged.
    assert_includes body, "showTokensPanel()"
    # The resume calls it DIRECTLY. It used to appear as `board.showTokensPanel()`
    # inside a setTimeout — the 3s deferral that let the magic-link welcome modal
    # drain its countdown first. That modal is retired, so the deferral and its
    # closure-captured `board` alias went with it; pinning the old spelling would
    # be pinning a dead branch.
    assert_includes body, "this.showTokensPanel();"
  end

  # --- hold-window funding pre-check wiring (render level; e2e gap noted above) ---
  #
  # The fix for the fresh-managed-wallet "0x1" sim error: the 2s hold's START
  # kicks off an authoritative server funding check (POST check_funding) that
  # confirmEntry awaits at hold-COMPLETE, rerouting an unfundable web2 entry to
  # the Top Up Wallet instead of a doomed on-chain attempt. These assert the
  # client wiring at render level; the live hold-window race is a tracked
  # Playwright e2e gap (same precedent as the on-chain success-modal coverage).

  test "both board hold buttons fire the funding pre-check on hold-start" do
    get contest_path(contests(:one))
    assert_response :success
    body = response.body
    # The shared hold_button renders on_hold_start as data-on-hold-start, and
    # both the desktop + mobile board buttons dispatch the hold-funding-check
    # window event (scope-independent, like hold-confirm-entry). The attribute
    # value's single quotes are HTML-escaped on render (&#39;), exactly like the
    # sibling data-on-success.
    assert_equal 2, body.scan("data-on-hold-start=").size,
                 "exactly the desktop + mobile board hold buttons carry on_hold_start"
    assert_includes body,
                    %(data-on-hold-start="window.dispatchEvent(new CustomEvent(&#39;hold-funding-check&#39;))"),
                    "the board hold buttons must dispatch hold-funding-check on hold-start"
  end

  test "the board listens for hold-funding-check and kicks off beginFundingCheck" do
    get contest_path(contests(:one))
    assert_response :success
    body = response.body
    assert_includes body, "window.addEventListener('hold-funding-check', function () {",
                     "the board must register a hold-funding-check listener"
    assert_match(/hold-funding-check.*\n.*board\.beginFundingCheck\(\)/, body,
                 "the listener must call beginFundingCheck()")
  end

  test "beginFundingCheck is web2-scoped and POSTs the authoritative check_funding endpoint" do
    get contest_path(contests(:one))
    assert_response :success
    body = response.body
    assert_includes body, "beginFundingCheck() {"
    # web3 is left alone (fail-open-on-flake preserved) — the check only fires
    # for a logged-in managed (web2) session.
    assert_includes body, "if (sess.mode !== 'web2') return;"
    # Fresh authoritative read against Carl's endpoint (relative path, contest-scoped).
    assert_includes body, "'/contests/' + this.contestId + '/check_funding'"
    # Stashed unawaited on the component for confirmEntry to consume.
    assert_includes body, "this._fundingCheck = window.authedFetch("
  end

  test "confirmEntry awaits the hold-window check and reroutes an unfundable web2 entry through showFundsNeeded" do
    get contest_path(contests(:one))
    assert_response :success
    body = response.body
    # The gate consumes the pre-check (single-use, freshness-bounded) and only a
    # DEFINITIVE fundable:false aborts into the funds-needed dispatcher — which
    # sends this web2 (managed) session to the Buy an Entry Token modal. Fail-open
    # otherwise. (The check is web2-scoped, so web3 never reaches this branch.)
    assert_includes body, "if (this._fundingCheck && (Date.now() - (this._fundingCheckAt || 0)) < 8000) {"
    assert_includes body, "this._fundingCheck = null;   // single-use — consume it for this attempt"
    assert_match(/if \(funding && funding\.fundable === false\) \{\s*\n\s*this\.submitting = false;\s*\n\s*this\.resetHoldButtons\(\);\s*\n\s*this\.showFundsNeeded\(\);/, body,
                 "an unfundable hold-window verdict must abort the entry through showFundsNeeded")
  end

  test "the eligibilityBlocker keeps web2 null-usdcCents fail-open and documents the hold-window layering" do
    # eligibilityBlocker ships as an importmap module (solana_utils.js), not
    # inlined in the page, so assert against the source. The synchronous web2
    # blocker must STILL fail OPEN on null usdcCents (a funded user with a cold
    # cache is never false-blocked); the genuinely-unfunded null case is the
    # hold-window server check's job — the comment must name it so a future edit
    # doesn't "fix" the fail-open and reintroduce the false-block.
    src = Rails.root.join("app/javascript/solana_utils.js").read
    assert_includes src, "if (session.usdcCents == null) return null;",
                    "web2 null-usdcCents must keep failing OPEN in the synchronous blocker"
    assert_match(/AUTHORITATIVE hold-window server check/, src,
                 "eligibilityBlocker must document that the hold-window check covers the null-balance case")
  end
end
