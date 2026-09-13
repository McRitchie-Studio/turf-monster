require "test_helper"
require "json"
require "open3"

# onchainSettled() — the one seam every web3-transaction-success path calls.
#
# WHAT IT IS FOR. A balance read taken right after a broadcast is a coin flip:
# the transaction is confirmed but the RPC has not necessarily caught up, so the
# read returns the PRE-SPEND number. Measured on QA 2026-09-07 — a $75 contest
# creation, a session_refresh 828ms after finalize returned, and a navbar that
# showed the old balance confidently for the next minute.
#
# The three properties below are the ones that were NOT free, and each is
# asserted against the real module executed in node.
class OnchainSettledJsTest < ActiveSupport::TestCase
  def run_module(body)
    source = Rails.root.join("app/javascript/solana_utils.js")
    script = <<~JS
      import { pathToFileURL } from 'node:url';

      const store = {};
      const painted = [];          // every write to the balance pill, in order
      const fetched = [];          // every session_refresh the module issues
      let now = 1_000_000;
      const realSetTimeout = globalThis.setTimeout;

      // A clock we control: the whole subject is WHEN a read happens.
      const timers = [];
      globalThis.setTimeout = (fn, ms) => { timers.push({ fn, at: now + (ms || 0) }); return timers.length; };
      const advance = (ms) => {
        now += ms;
        timers.filter(t => t.at <= now && !t.done).forEach(t => { t.done = true; t.fn(); });
      };
      const RealDate = Date;
      globalThis.Date = class extends RealDate { static now() { return now; } };

      const pill = { textContent: '$1239', classList: { _s: new Set(), add(c) { this._s.add(c); }, remove(c) { this._s.delete(c); }, has(c) { return this._s.has(c); }, contains(c) { return this._s.has(c); } } };
      globalThis.document = {
        querySelectorAll(sel) { return sel === '[data-balance-display]' ? [pill] : []; },
        querySelector(sel) { return sel === '[data-balance-display]' ? pill : null; },
        getElementById() { return null; },
        addEventListener() {}, dispatchEvent() {}
      };
      globalThis.localStorage = { _d: {}, setItem(k, v) { this._d[k] = v; }, getItem(k) { return this._d[k] ?? null; }, removeItem(k) { delete this._d[k]; } };
      const sessionStore = { _d: {}, setItem(k, v) { this._d[k] = String(v); }, getItem(k) { return this._d[k] ?? null; }, removeItem(k) { delete this._d[k]; } };

      const seedsEvents = [];
      globalThis.window = {
        sessionStorage: sessionStore,
        localStorage: globalThis.localStorage,
        addEventListener() {},
        dispatchEvent(e) { if (e && e.type === 'navbar-seeds-update') seedsEvents.push(e); return true; }
      };
      globalThis.CustomEvent = class { constructor(type, init) { this.type = type; this.detail = (init || {}).detail; } };
      globalThis.Alpine = { store(n, v) { if (arguments.length === 2) store[n] = v; return store[n]; } };
      globalThis.Alpine.store('session', {});

      // The server always answers with the SETTLED number here; the question is
      // only whether the module asks at the right time and paints in between.
      globalThis.fetch = (url) => {
        fetched.push({ url, at: now });
        return Promise.resolve({ ok: true, json: () => Promise.resolve({
          usdc: '1164.0', usdt: '0', tokens: 0, seeds: 10, level: 2, toward_next: 5, progress: 50
        }) });
      };

      const mod = await import(pathToFileURL(process.argv[1]).href + '?t=' + RealDate.now());
      const settle = (ms) => new Promise(r => realSetTimeout(r, ms));
      #{body}
    JS

    stdout, stderr, status = Open3.capture3(
      "node", "--input-type=module", "--eval", script, source.to_s
    )
    assert status.success?, stderr
    JSON.parse(stdout)
  end

  # PROPERTY 1 — the navigating caller. Contest creation assigns
  # window.location.href the moment the server answers, and a setTimeout does
  # not survive unload. If this scheduled a timer instead of leaving a marker it
  # would be a SILENT no-op on the exact flow it was built for.
  test "a navigating caller leaves a marker instead of a doomed timer" do
    r = run_module(<<~JS)
      mod.onchainSettled({ navigating: true });
      const markerWritten = sessionStore.getItem('tm:onchain-settle-until');
      advance(60000);                       // the unload would have killed a timer
      const fetchedWhileNavigating = fetched.length;

      // The destination page consumes it and gets the REMAINING window.
      const remaining = mod.pendingOnchainSettleMs();
      const clearedAfterRead = sessionStore.getItem('tm:onchain-settle-until');
      const secondRead = mod.pendingOnchainSettleMs();

      console.log(JSON.stringify({ markerWritten, fetchedWhileNavigating, remaining, clearedAfterRead, secondRead }));
    JS

    assert_not_nil r["markerWritten"],
      "a navigating caller must persist the settle window; a timer would die on unload"
    assert_equal 0, r["fetchedWhileNavigating"],
      "it must NOT schedule its own read — that read belongs to the destination page"
    assert_equal 0, r["remaining"],
      "the marker's window had already elapsed, so the destination settles immediately"
    assert_nil r["clearedAfterRead"], "reading the marker must consume it"
    assert_nil r["secondRead"],
      "a second read must find nothing — otherwise a reload re-arms the wait forever"
  end

  # PROPERTY 2 — never a wrong number. This is the operator's call: hold the
  # loading state rather than paint a value we have reason to distrust.
  test "the pill goes to loading and is painted ONCE, after the settle window" do
    r = run_module(<<~JS)
      mod.onchainSettled({ delayMs: 10000 });
      const duringWait = { text: pill.textContent, hidden: pill.classList.has('hidden'), fetches: fetched.length };
      advance(9999);
      const justBefore = { fetches: fetched.length, text: pill.textContent };
      advance(2);
      await settle(30);
      const after = { fetches: fetched.length, text: pill.textContent, hidden: pill.classList.has('hidden') };
      console.log(JSON.stringify({ duringWait, justBefore, after }));
    JS

    assert_equal "", r.dig("duringWait", "text"),
      "the stale figure must be cleared the moment the spend is known — not left on screen"
    assert r.dig("duringWait", "hidden"),
      "the pill must return to the server's cache-cold LOADING shape while it waits"
    assert_equal 0, r.dig("duringWait", "fetches"),
      "no read during the wait — reading early is the whole bug"
    assert_equal 0, r.dig("justBefore", "fetches"),
      "still nothing at 9999ms; the window must actually be honoured"
    assert_equal 1, r.dig("after", "fetches"),
      "exactly one read, once the chain has had its ten seconds"
    assert_equal "$1164", r.dig("after", "text"), "and it paints the SETTLED number"
    assert_not r.dig("after", "hidden"), "loading clears once a trustworthy value lands"
  end

  # PROPERTY 4 — the load-time decision the layout delegates to.
  #
  # This is the seam that makes the redirect work end to end, and it used to be
  # three lines of inline ERB that no test could execute. Extracted so it can be.
  test "the page that receives the redirect defers its own read, exactly once" do
    r = run_module(<<~JS)
      // (a) no spend happened — the page hydrates normally.
      const cleanPage = mod.settleOnLoadIfPending();
      const fetchesAfterClean = fetched.length;

      // (b) a spend happened on the page that sent us here.
      mod.onchainSettled({ navigating: true, delayMs: 10000 });
      const deferred = mod.settleOnLoadIfPending();
      const paintedDuringWait = { text: pill.textContent, hidden: pill.classList.has('hidden') };
      const fetchesDuringWait = fetched.length;
      advance(10001);
      await settle(30);
      const fetchesAfterSettle = fetched.length;

      // (c) a RELOAD after settling must not defer again.
      const secondLoad = mod.settleOnLoadIfPending();

      console.log(JSON.stringify({ cleanPage, fetchesAfterClean, deferred, paintedDuringWait, fetchesDuringWait, fetchesAfterSettle, secondLoad }));
    JS

    assert_equal false, r["cleanPage"],
      "with no spend pending it must return false so the normal load-time hydrate still runs — " \
      "returning true here would silently stop the navbar ever hydrating"
    assert_equal 0, r["fetchesAfterClean"], "and it must not read on its own in that case"

    assert_equal true, r["deferred"],
      "a pending spend must take over the load, or the layout does its own early read — " \
      "the exact read that painted the stale $1239"
    assert_equal "", r.dig("paintedDuringWait", "text")
    assert r.dig("paintedDuringWait", "hidden"), "the pill holds LOADING across the redirect"
    assert_equal 0, r["fetchesDuringWait"], "no read during the inherited window"
    assert_equal 1, r["fetchesAfterSettle"], "exactly one read, after it settles"

    assert_equal false, r["secondLoad"],
      "a later reload must hydrate normally — the marker is consumed, so the wait cannot re-arm"
  end

  # PROPERTY 5 — the double fire. hydrateNavbar runs on BOTH DOMContentLoaded
  # and turbo:load. Found in a BROWSER, not here: the node tests below all
  # passed while the second call undid the defer a millisecond later.
  test "the defer releases its guard only when the window closes" do
    r = run_module(<<~JS)
      mod.onchainSettled({ navigating: true, delayMs: 10000 });

      let released = false;
      const first = mod.settleOnLoadIfPending(() => { released = true; });
      const releasedDuringWait = released;

      // The SECOND fire. The marker is already consumed, so this returns false
      // — which is exactly why the caller must hold a guard of its own until
      // the callback says the window closed.
      const second = mod.settleOnLoadIfPending(() => {});

      advance(10001);
      await settle(30);
      console.log(JSON.stringify({ first, second, releasedDuringWait, releasedAfter: released }));
    JS

    assert_equal true, r["first"], "the first fire takes the window"
    assert_equal false, r["second"],
      "the second fire finds the marker consumed — so it would fall through to a normal " \
      "hydrate and read the chain early unless the caller is still holding its guard"
    assert_equal false, r["releasedDuringWait"],
      "the guard must stay held for the WHOLE window, not released on the next tick"
    assert_equal true, r["releasedAfter"],
      "and it must be released once settled, or the navbar never hydrates again"
  end

  # PROPERTY 6 — ONE WRITER OWNS THE PILL. The level-up token poller calls
  # refreshSession() at +1000/2500/5000/9000ms after a level-up entry. Inside a
  # settle window those are the same too-early reads the seam refuses; painting
  # one clears loading and presents the PRE-SPEND number as the answer.
  # Measured by review at ~7.6s of the wrong figure.
  test "a competing refresh may not paint the balance while a settle is pending" do
    r = run_module(<<~JS)
      // The chain still reports the PRE-SPEND number — this is the whole point.
      // A fixture that answers 1164 to everyone cannot express this bug, which
      // is exactly why the e2e missed it.
      let chain = '1239.0';
      globalThis.fetch = (url) => {
        fetched.push({ url, at: now });
        return Promise.resolve({ ok: true, json: () => Promise.resolve({
          usdc: chain, usdt: '0', tokens: 0, seeds: 0, level: 1, toward_next: 0, progress: 0
        }) });
      };

      mod.onchainSettled({ delayMs: 10000 });
      const afterBlank = pill.textContent;

      // The poller's reads land INSIDE the window.
      advance(1000);  await mod.refreshSession(); await settle(10);
      advance(1500);  await mod.refreshSession(); await settle(10);
      const duringWindow = { text: pill.textContent, hidden: pill.classList.has('hidden') };

      // The chain catches up, then the settle fires and IS allowed to paint.
      chain = '1164.0';
      advance(10000); await settle(40);
      const afterSettle = { text: pill.textContent, hidden: pill.classList.has('hidden') };
      console.log(JSON.stringify({ afterBlank, duringWindow, afterSettle }));
    JS

    assert_equal "", r["afterBlank"]
    assert_equal "", r.dig("duringWindow", "text"),
      "a competing read inside the window must NOT paint — it would show $1239, the pre-spend number"
    assert r.dig("duringWindow", "hidden"), "and must not clear the loading state either"
    assert_equal "$1164", r.dig("afterSettle", "text"),
      "the settle's own read still paints — the guard is about WHO writes, not a freeze"
    assert_not r.dig("afterSettle", "hidden")
  end

  # PROPERTY 7 — a failed or REFUSED settle must not leave the navbar blank.
  # paintBalanceLoading clears the pill before the wait, and refreshSession
  # swallows failure, so without this the pill stays empty for good — worse than
  # the stale-but-visible number it replaced.
  test "a failed settle retries, then restores what the pill had" do
    r = run_module(<<~JS)
      pill.textContent = '$1239';
      let failures = 99;                       // fail everything
      globalThis.fetch = () => { fetched.push({ at: now }); return Promise.reject(new Error('offline')); };

      mod.onchainSettled({ delayMs: 10000 });
      advance(10001); await settle(20);
      const afterFirstFail = { text: pill.textContent, reads: fetched.length };

      advance(3001); await settle(40);         // the retry
      const afterRetry = { text: pill.textContent, hidden: pill.classList.has('hidden'), reads: fetched.length };
      console.log(JSON.stringify({ afterFirstFail, afterRetry }));
    JS

    assert_equal 1, r.dig("afterFirstFail", "reads"), "one read at the window"
    assert_equal "", r.dig("afterFirstFail", "text"),
      "still blank between the failure and the retry — we have not given up yet"
    assert_equal 2, r.dig("afterRetry", "reads"), "exactly one retry, not a loop"
    assert_equal "$1239", r.dig("afterRetry", "text"),
      "after the retry also fails, put back what was on the pill — a blank navbar reads as broken " \
      "and invites a refresh that can itself refuse the settle"
    assert_not r.dig("afterRetry", "hidden"), "and make it visible again"
  end

  # PROPERTY 7b — the RPC flake that answers 200. session_refresh emits
  # usdc AND usdt null when the wallet read flaked, and refreshSession paints
  # nothing on that shape — a failure the reject test above cannot reach.
  test "a settle that lands with no balances restores the pill too" do
    r = run_module(<<~JS)
      pill.textContent = '$1239';
      globalThis.fetch = () => { fetched.push({ at: now }); return Promise.resolve({ ok: true, json: () => Promise.resolve({ usdc: null, usdt: null, tokens: 0, seeds: 0, level: 1, toward_next: 0, progress: 0 }) }); };
      mod.onchainSettled({ delayMs: 10000 });
      advance(10001); await settle(20);
      advance(3001);  await settle(40);
      console.log(JSON.stringify({ text: pill.textContent, hidden: pill.classList.has('hidden'), reads: fetched.length }));
    JS

    assert_equal 2, r["reads"], "a null-balance payload is a failed settle — it must retry"
    assert_equal "$1239", r["text"], "then put the number back, not leave the navbar with no balance at all"
    assert_not r["hidden"]
  end

  # PROPERTY 3 — the seeds guard. Converging every path onto a delayed FULL
  # reload means that reload can land mid level-up animation.
  test "the delayed reload leaves the seeds bar alone while it is animating" do
    r = run_module(<<~JS)
      mod.markSeedsAnimating(3000);
      await mod.refreshSession();
      const during = { events: seedsEvents.length, stored: localStorage.getItem('seedsNavbar') };

      advance(3001);                       // animation over
      await mod.refreshSession();
      const after = { events: seedsEvents.length, stored: localStorage.getItem('seedsNavbar') };
      console.log(JSON.stringify({ during, after }));
    JS

    assert_equal 0, r.dig("during", "events"),
      "no seeds event while the animation owns the bar — it would snap the bar back or re-fire the milestone"
    assert_nil r.dig("during", "stored"),
      "and no canonical seeds write either; the animation is mid-flight toward that value"
    assert_equal 1, r.dig("after", "events"),
      "once the animation is done the reload repaints seeds normally — the guard is a WINDOW, not an off switch"
    assert_not_nil r.dig("after", "stored")
  end

  # ── THE STAY-PUT-BUT-MAY-NAVIGATE CALLER ──────────────────────────────────
  #
  # PROPERTY 8/9/10 are one fix in three halves, so they are asserted as three
  # tests: schedule in-page, leave the marker anyway, and retire the marker once
  # the in-page read lands.
  #
  # THE SURFACE THAT NEEDED IT (survivor-settle-never-fires). The survivor board
  # was calling onchainSettled({ navigating: true }) on the belief that its
  # success card auto-redirects. It does not — it sets no lobbyUrl, so the
  # engine's startCountdown() returns early and no countdown is armed. So the
  # marker was written for a navigation that never came, nothing was scheduled,
  # and the navbar held the PRE-SPEND figure for as long as the card stayed open.
  # The other either/or branch is no better: the user leaves that card by CLOSING
  # it, and modal.onClose assigns window.location, which destroys a bare timer.

  # PROPERTY 8 — the half PR #609 removed. A mayNavigate caller must settle the
  # pill IN PLACE for the user who never leaves the page.
  test "a mayNavigate caller settles the pill in place, exactly like a stay-put one" do
    r = run_module(<<~JS)
      mod.onchainSettled({ mayNavigate: true, delayMs: 10000 });
      const onSpend = { text: pill.textContent, hidden: pill.classList.has('hidden'), reads: fetched.length };

      advance(9999);
      const justBefore = fetched.length;
      advance(2);
      await settle(30);
      const after = { text: pill.textContent, hidden: pill.classList.has('hidden'), reads: fetched.length };
      console.log(JSON.stringify({ onSpend, justBefore, after }));
    JS

    assert_equal "", r.dig("onSpend", "text"),
      "the stale figure must be cleared on the spend — a marker-only caller never blanked it, " \
      "which is how the navbar kept showing the pre-spend balance while the card sat open"
    assert r.dig("onSpend", "hidden"), "and the pill must hold the server's cache-cold LOADING shape"
    assert_equal 0, r.dig("onSpend", "reads"), "no read on the spend itself"
    assert_equal 0, r["justBefore"], "nothing at 9999ms — the window is honoured"
    assert_equal 1, r.dig("after", "reads"),
      "the read must actually be SCHEDULED here; a navigating caller schedules nothing at all, " \
      "so on a surface that does not redirect the settle simply never fires"
    assert_equal "$1164", r.dig("after", "text"), "and it paints the settled number in place"
    assert_not r.dig("after", "hidden")
  end

  # PROPERTY 9 — and the marker anyway, for the user who DOES leave. Closing the
  # survivor card navigates, so this is the normal exit, not an edge case. The
  # destination is modelled as a genuinely fresh module instance: separate module
  # state, same sessionStorage, with page A's timers destroyed the way an unload
  # destroys them.
  test "a mayNavigate settle survives a close-triggered navigation" do
    r = run_module(<<~JS)
      mod.onchainSettled({ mayNavigate: true, delayMs: 10000 });
      const markerOnSpend = sessionStore.getItem('tm:onchain-settle-until');

      advance(2000);                        // the user closes the card two seconds in
      const readsBeforeUnload = fetched.length;
      timers.forEach(t => { t.done = true; });   // ...and modal.onClose navigates: UNLOAD

      // The destination page: a fresh module, the same sessionStorage.
      const modB = await import(pathToFileURL(process.argv[1]).href + '?page=B' + RealDate.now());
      const deferred = modB.settleOnLoadIfPending();
      const onArrival = { text: pill.textContent, hidden: pill.classList.has('hidden'), reads: fetched.length };

      advance(8001);                        // the REMAINDER of the original window
      await settle(40);
      const after = { text: pill.textContent, hidden: pill.classList.has('hidden'), reads: fetched.length };
      console.log(JSON.stringify({ markerOnSpend, readsBeforeUnload, deferred, onArrival, after }));
    JS

    assert_not_nil r["markerOnSpend"],
      "the marker must be written even though this caller also scheduled — the schedule is the " \
      "half that dies at the close, and the close is how people leave this card"
    assert_equal 0, r["readsBeforeUnload"], "nothing read before the user left"
    assert_equal true, r["deferred"],
      "the destination must inherit the window, or it does its own load-time read — the " \
      "too-early read this whole seam exists to refuse"
    assert_equal "", r.dig("onArrival", "text"), "the pill holds LOADING across the navigation"
    assert r.dig("onArrival", "hidden")
    assert_equal 0, r.dig("onArrival", "reads"), "and reads nothing on arrival"
    assert_equal 1, r.dig("after", "reads"), "exactly one read, when the inherited window closes"
    assert_equal "$1164", r.dig("after", "text"),
      "the settled number lands at the destination — the settle was not lost by leaving"
  end

  # PROPERTY 10 — THE SUBTLE HALF. Once the in-page read has landed, the marker
  # has been served and must be gone. Leave it and a user who closes the card
  # LATER arrives at a page that consumes a spent marker, blanks a pill already
  # showing the settled number, and holds it blank for another full window.
  test "a landed in-page read retires the marker, so a later navigation does not re-blank" do
    r = run_module(<<~JS)
      mod.onchainSettled({ mayNavigate: true, delayMs: 10000 });
      advance(10001);
      await settle(40);
      const settledInPlace = { text: pill.textContent, hidden: pill.classList.has('hidden') };
      const markerAfterSettle = sessionStore.getItem('tm:onchain-settle-until');

      // Only NOW does the user close the card, and onClose navigates.
      timers.forEach(t => { t.done = true; });
      const modB = await import(pathToFileURL(process.argv[1]).href + '?page=C' + RealDate.now());
      const deferredAtDestination = modB.settleOnLoadIfPending();
      const onArrival = { text: pill.textContent, hidden: pill.classList.has('hidden') };
      console.log(JSON.stringify({ settledInPlace, markerAfterSettle, deferredAtDestination, onArrival }));
    JS

    assert_equal "$1164", r.dig("settledInPlace", "text"), "the in-page settle landed first"
    assert_nil r["markerAfterSettle"],
      "a landed read must retire the marker — it has been served, and a spent marker is a " \
      "second settle window waiting to blank a pill that is already correct"
    assert_equal false, r["deferredAtDestination"],
      "so the destination hydrates normally instead of inheriting a window that is already over"
    assert_equal "$1164", r.dig("onArrival", "text"),
      "and the settled figure survives the navigation rather than blanking itself again"
    assert_not r.dig("onArrival", "hidden")
  end

  # PROPERTY 10b — the OTHER side of that rule, which is why the clear is
  # conditional. A read that did not land has served nothing, so the marker
  # stays: the destination becomes a second chance at the settle. Clearing
  # unconditionally would spend the marker on a failure and strand the navbar on
  # the restored, stale figure.
  test "a settle that never landed keeps its marker for the destination" do
    r = run_module(<<~JS)
      pill.textContent = '$1239';
      globalThis.fetch = () => { fetched.push({ at: now }); return Promise.reject(new Error('offline')); };

      mod.onchainSettled({ mayNavigate: true, delayMs: 10000 });
      advance(10001); await settle(20);
      advance(3001);  await settle(40);          // the retry fails too
      const afterFailedSettle = { text: pill.textContent, reads: fetched.length };
      const markerKept = sessionStore.getItem('tm:onchain-settle-until');
      console.log(JSON.stringify({ afterFailedSettle, markerKept }));
    JS

    assert_equal 2, r.dig("afterFailedSettle", "reads"), "one read plus one retry, both failed"
    assert_equal "$1239", r.dig("afterFailedSettle", "text"), "the stale figure is restored, as before"
    assert_not_nil r["markerKept"],
      "nothing landed, so nothing was served — the marker must survive so a navigation still " \
      "gets a settle instead of trusting the number we just put back"
  end

  # PROPERTY 10c — THE RETIRE IS SCOPED TO THE WINDOW IT SERVED, NOT TO THE KEY.
  #
  # Property 10 says a landed read retires the marker. This says WHICH marker,
  # and it is the difference between a fix and a wider bug.
  #
  # The write and the retire are separated in time (see writeOnchainSettleMarker),
  # so by the time a read lands the slot can hold a DIFFERENT spend's marker. A
  # retire that deleted the KEY took that one with it.
  #
  # THE SEQUENCE IS ORDINARY. Spend, close the card — which navigates — spend
  # again on the page you land on. Spend #1's read is now DEFERRED onto that
  # second page and owns no marker at all; when it landed it wiped spend #2's.
  # Spend #2 then settled NOWHERE: its in-page timer died at the next
  # navigation, and the destination inherited nothing, so it hydrated normally
  # and painted the PRE-SPEND figure with .hidden cleared, presented as the
  # answer. That is the exact failure this seam exists to refuse, re-created on
  # a surface this task never meant to touch.
  test "a landed read retires only its own marker, not a later spend's" do
    r = run_module(<<~JS)
      // The chain catches up in STAGES, so the two spends are distinguishable:
      // $1239 pre-spend, $1164 once spend #1 has settled at t=10s, $1100 once
      // spend #2 has settled at t=14s. A fixture answering one number to
      // everyone cannot tell which spend a read served — which is how a probe
      // against the shipped stub showed nothing wrong here.
      const T0 = now;
      globalThis.fetch = () => {
        const v = now < T0 + 10000 ? '1239.0' : (now < T0 + 14000 ? '1164.0' : '1100.0');
        fetched.push({ at: now - T0, gave: v });
        return Promise.resolve({ ok: true, json: () => Promise.resolve({
          usdc: v, usdt: '0', tokens: 0, seeds: 0, level: 1, toward_next: 0, progress: 0
        }) });
      };

      // PAGE A — spend #1. The user closes the card two seconds in, and
      // modal.onClose assigns window.location: UNLOAD kills page A's timer.
      mod.onchainSettled({ mayNavigate: true, delayMs: 10000 });
      advance(2000);
      timers.forEach(t => { t.done = true; });

      // PAGE B — inherits spend #1's window. Note what it does NOT get: a
      // marker of its own, because settleOnLoadIfPending consumed the one it
      // arrived on.
      const modB = await import(pathToFileURL(process.argv[1]).href + '?page=B' + RealDate.now());
      const inherited = modB.settleOnLoadIfPending();

      // ...and spend #2 happens ON page B, two seconds after landing.
      advance(2000);
      modB.onchainSettled({ mayNavigate: true, delayMs: 10000 });
      const markerOfSpend2 = sessionStore.getItem('tm:onchain-settle-until');

      // Spend #1's inherited read lands at t=10s. THE MOMENT UNDER TEST.
      advance(6001);
      await settle(40);
      const markerAfterSpend1Read = sessionStore.getItem('tm:onchain-settle-until');
      const afterSpend1Read = { text: pill.textContent, hidden: pill.classList.has('hidden') };

      // PAGE C — the user closes spend #2's card at t=11s, before its own
      // in-page read could fire. The marker is the only thing left carrying it.
      advance(1000);
      timers.forEach(t => { t.done = true; });
      const modC = await import(pathToFileURL(process.argv[1]).href + '?page=C' + RealDate.now());
      const deferredAtC = modC.settleOnLoadIfPending();
      const onArrivalAtC = { text: pill.textContent, hidden: pill.classList.has('hidden') };

      advance(5000);
      await settle(40);
      const final = { text: pill.textContent, hidden: pill.classList.has('hidden') };
      console.log(JSON.stringify({ inherited, markerOfSpend2, markerAfterSpend1Read,
                                   afterSpend1Read, deferredAtC, onArrivalAtC, final, reads: fetched }));
    JS

    assert_equal true, r["inherited"], "page B must inherit spend #1's window"
    assert_not_nil r["markerOfSpend2"], "spend #2 arms its own marker on page B"
    assert_equal "$1164", r.dig("afterSpend1Read", "text"),
      "spend #1's deferred read lands and paints, exactly as before"

    # THE ASSERTION THE DEFECT FAILS.
    assert_equal r["markerOfSpend2"], r["markerAfterSpend1Read"],
      "spend #1's read owns NO marker — it must retire nothing. Deleting the key here takes " \
      "spend #2's window with it, and spend #2 then never settles anywhere"

    assert_equal true, r["deferredAtC"],
      "so the page the user lands on still inherits spend #2's window instead of hydrating " \
      "normally and reading the chain early"
    assert_equal "", r.dig("onArrivalAtC", "text"),
      "and holds LOADING rather than presenting spend #2's pre-spend figure as the answer"
    assert r.dig("onArrivalAtC", "hidden")
    assert_equal "$1100", r.dig("final", "text"),
      "the number that finally lands is the one AFTER spend #2 — $1164 here would be the " \
      "pre-spend balance for the second spend, which is the whole bug"
    assert_not r.dig("final", "hidden")
  end

  # PROPERTY 6' — A MARKER WITH ZERO MS LEFT IS STILL A MARKER.
  #
  # settleOnLoadIfPending tests `pendingMs == null`, not `!pendingMs`, and
  # pendingOnchainSettleMs floors its answer at 0. Before mayNavigate existed
  # that distinction was cosmetic: a navigating caller navigates immediately, so
  # its marker always arrived with most of its window intact. mayNavigate makes
  # a spent-but-surviving marker ORDINARY — the user closes the card long after
  # the window elapsed — so the distinction became load-bearing and nothing
  # pinned it.
  #
  # WHAT `!pendingMs` WOULD COST. Returning false hands the load back to the
  # layout's ordinary hydrate, and that read is NOT equivalent: it runs on the
  # default 'session' lock, contended by the level-up poller and both refresh
  # buttons, and lockedFetch answers a contender with Promise.resolve(null). It
  # has no retry. The settle path takes its own 'onchain-settle' key and retries
  # once. So on the one load where the pill is showing a figure a failed settle
  # restored, the weaker read is the one that would run.
  test "a marker whose window has already elapsed still takes the load" do
    r = run_module(<<~JS)
      pill.textContent = '$1239';
      globalThis.fetch = () => { fetched.push({ at: now }); return Promise.reject(new Error('offline')); };

      // A mayNavigate spend whose settle fails outright, so the marker is
      // deliberately KEPT (property 10b) and outlives its own window.
      mod.onchainSettled({ mayNavigate: true, delayMs: 10000 });
      advance(10001); await settle(20);
      advance(3001);  await settle(40);        // the retry fails too; pill restored
      const markerKept = sessionStore.getItem('tm:onchain-settle-until');
      const beforeNav = { text: pill.textContent, reads: fetched.length };

      // Only NOW does the user close the card. The window elapsed 3s ago, so
      // the destination inherits a REMAINING of exactly 0.
      timers.forEach(t => { t.done = true; });
      globalThis.fetch = () => {
        fetched.push({ at: now });
        return Promise.resolve({ ok: true, json: () => Promise.resolve({
          usdc: '1164.0', usdt: '0', tokens: 0, seeds: 0, level: 1, toward_next: 0, progress: 0
        }) });
      };
      const modB = await import(pathToFileURL(process.argv[1]).href + '?page=B' + RealDate.now());
      const deferred = modB.settleOnLoadIfPending();
      const onArrival = { text: pill.textContent, hidden: pill.classList.has('hidden'), reads: fetched.length };

      advance(1); await settle(40);
      const after = { text: pill.textContent, hidden: pill.classList.has('hidden'), reads: fetched.length };
      console.log(JSON.stringify({ markerKept, beforeNav, deferred, onArrival, after }));
    JS

    assert_not_nil r["markerKept"], "the failed settle kept its marker (property 10b)"
    assert_equal "$1239", r.dig("beforeNav", "text"), "and restored the stale figure"

    # THE ASSERTION THE MUTANT FAILS.
    assert_equal true, r["deferred"],
      "zero milliseconds remaining is not 'no marker pending' — a spend DID happen on the page " \
      "that sent us here, so the settle must still own this load. `!pendingMs` reads a floored 0 " \
      "as absent and hands the read to the contendable, un-retried hydrate instead"

    assert_equal "", r.dig("onArrival", "text"),
      "so the restored stale figure is cleared rather than trusted"
    assert r.dig("onArrival", "hidden")
    assert_equal r.dig("beforeNav", "reads"), r.dig("onArrival", "reads"),
      "and nothing is read before the (zero-length) window closes"
    assert_equal "$1164", r.dig("after", "text"), "the settle's own read lands immediately and paints"
    assert_not r.dig("after", "hidden")
    assert_equal r.dig("beforeNav", "reads") + 1, r.dig("after", "reads"), "exactly one read, not two"
  end

  # PROPERTY 10d — THE MARKER FROM THE PREVIOUS DEPLOY.
  #
  # Scoping the retire changed the marker's stored SHAPE, from "<until>" to
  # "<until>:<id>", and a deploy does not swap every loaded bundle at once. A
  # tab that loaded the old JS writes the old shape, and a back-navigation into
  # a bfcached page runs that bundle again in the same tab. So both shapes are
  # live at once for a while, and the new code owes them two things.
  #
  # ONE — it must still read the deadline. parseInt stops at the colon, which is
  # why the id was appended rather than put in a second key or a JSON blob;
  # nothing about that is obvious from the call site, so it is asserted here.
  #
  # TWO — it must not retire one. An id-less marker matches no settle's id, and
  # a settle that wrote no marker of its own (the deferred read below) owns
  # nothing to retire. Dropping that guard and leaning on the id comparison
  # alone reads null === null as a match and deletes the marker — the same
  # cross-spend wipe as property 10c, arriving by the other door.
  test "a marker in the pre-deploy shape is honoured and never retired by a stranger" do
    r = run_module(<<~JS)
      const KEY = 'tm:onchain-settle-until';

      // Spend #1's marker, in the shape the previous deploy's writer produced:
      // a bare deadline. Seeded directly because this writer cannot make one.
      sessionStore.setItem(KEY, String(now + 10000));
      const inherited = mod.settleOnLoadIfPending();
      const readsOnArrival = fetched.length;
      const onArrival = { text: pill.textContent, hidden: pill.classList.has('hidden') };

      // The old bundle runs again in this tab and arms a second spend the same
      // old way, four seconds in.
      advance(4000);
      sessionStore.setItem(KEY, String(now + 10000));
      const legacyMarkerOfSpend2 = sessionStore.getItem(KEY);

      // Spend #1's deferred read lands. It owns no marker, so it retires none.
      advance(6001);
      await settle(40);
      console.log(JSON.stringify({ inherited, readsOnArrival, onArrival, legacyMarkerOfSpend2,
                                   markerAfter: sessionStore.getItem(KEY),
                                   readsAfter: fetched.length, text: pill.textContent }));
    JS

    assert_equal true, r["inherited"],
      "the pre-deploy shape must still hand its window over — the id is appended after a colon " \
      "precisely so parseInt keeps reading the deadline out of both shapes"
    assert_equal 0, r["readsOnArrival"], "and the inherited window is actually honoured"
    assert_equal "", r.dig("onArrival", "text")
    assert r.dig("onArrival", "hidden")
    assert_equal 1, r["readsAfter"], "one read, when that window closes"
    assert_equal "$1164", r["text"]

    # THE ASSERTION THE MUTANT FAILS.
    assert_equal r["legacyMarkerOfSpend2"], r["markerAfter"],
      "an id-less marker belongs to no settle here, so nothing may retire it. Without the " \
      "'wrote no marker, retire nothing' guard, null === null reads as a match and this read " \
      "deletes the second spend's window"
  end
end
