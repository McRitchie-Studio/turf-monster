// COMING BACK FROM A WALLET THAT NEVER ANSWERED — both ways back, in a real browser.
//
// /tasks/frozen-wallet-overlay-traps-user. The trap, in the order a phone walks
// it: the user holds to enter, the NON-DISMISSIBLE processing card paints
// "Opening Your Wallet", the wallet takes the screen, and the user changes their
// mind and comes back without acting. The page comes back exactly as it left —
// card up, body scroll-locked by `html:has(body.modal-open) { overflow: hidden }`
// (which also kills pull-to-refresh) — and before this fix nothing was left
// watching, so the user was stuck until they closed the tab.
//
// AND A THIRD LEG SHARES THE HARNESS (/tasks/stranded-handoff-buries-card): the
// hop that NEVER happens. Nothing takes the universal link — no wallet app
// installed, or the user dismisses the OS prompt — so this document stays alive
// and VISIBLE, and the runner's grace window is what notices. It reaches the
// same buried card the way back does, so it belongs beside these two.
//
// THE TWO WAYS BACK ARE DIFFERENT MECHANISMS, and each test drives one:
//
//   1. THE PAGE WAS LEFT AND RESTORED. The browser navigated to the wallet's
//      universal link, the document went into the back/forward cache, and the
//      user swiped back. The return is a `pageshow` with `persisted`.
//   2. THE PAGE WAS NEVER LEFT. The OS took the universal link into the wallet
//      APP and the browser's navigation never committed, so the document is
//      alive behind the wallet. The return is a `visibilitychange`, and nothing
//      is restored, so no pageshow fires. This is the shape a phone takes, and
//      it is also the one where studio-engine's own bfcache cleanup never runs
//      — which is what makes the SECOND test's composition bite.
//
// WHY TEST 2 STACKS A CELEBRATION. Review of PR 697 (2026-09-12): the level-up
// modal opens ON TOP of a non-dismissible card rather than swapping it away
// (layouts/application.html.erb says so where it does it), so an abandoned
// handoff can leave the processing card BURIED. A return handler that reads
// `$store.solanaModal.visible` / `.state` — both current-only — then retires
// nothing, and the frozen card reappears the moment the celebration closes,
// with the scroll lock still on. So the composed test asserts the buried card
// is gone AND the page scrolls once the celebration is closed.
//
// WHY THIS FILE LAUNCHES ITS OWN BROWSER. Three things stood between this lane
// and a real bfcache restore, each measured with CDP's
// Page.backForwardCacheNotUsed:
//
//   1. THE SWITCH. Playwright starts Chromium with --disable-back-forward-cache
//      (playwright-core 1.58.2, lib/server/chromium/chromiumSwitches.js:59,
//      measured 2026-09-13), so every other page.goBack() in this suite is a
//      fresh load or a Turbo restore. `ignoreDefaultArgs` drops that one switch.
//   2. THE SHELL. Even without the switch, the default headless shell refuses
//      every page, a static one included — BackForwardCacheDisabledForDelegate,
//      which the page itself sees only as "masked". channel "chromium" runs the
//      full build in new headless mode, which caches. `playwright install
//      chromium` in CI installs both builds.
//   3. THE CABLE. The board holds turbo's Action Cable socket open, and Chromium
//      will not cache a page with a live WebSocket (reason "WebSocket",
//      SupportPending). So test 1 closes that socket before the handoff. It
//      makes the page ELIGIBLE and changes nothing the restore brings back —
//      the card, the scroll lock and the board's state are untouched.
//
// All three are worker options, so this file gets a worker of its own and
// nothing else in the lane changes.
//
// AND EACH TEST PROVES ITS MECHANISM BEFORE IT PROVES THE FIX. A green run
// reached the wrong way would be worthless: a freshly loaded document has no
// card at all, and a page that never went hidden was never returned to. So test
// 1 shows the SAME document came back and logged a persisted pageshow (with
// Chrome's notRestoredReasons in the failure message if it did not), and test 2
// shows the document recorded hidden-then-visible without ever unloading.
//
// WHAT THIS CANNOT SEE, said plainly: this is Chromium with an iPhone user
// agent, not iOS WebKit. Whether Safari caches this board with its socket open
// is not measurable here — Playwright's WebKit restored not even a static page
// — and no harness here proves what Phantom itself does with these URLs. Only a
// phone does; /tasks/verify-wallets-on-a-phone carries that check.
const { test, expect } = require("@playwright/test");
const { installStubWallet } = require("./stub-wallet");

const IPHONE =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

// The seeded standard contest, which renders the turf-totals board
// (e2e/seed.rb pins it as the main contest).
const BOARD_CONTEST = "/contests/world-cup-2026";

test.use({
  userAgent: IPHONE,
  channel: "chromium",
  launchOptions: { ignoreDefaultArgs: ["--disable-back-forward-cache"] },
});

// Stub ONLY the server's prepare, as e2e/stub_wallet_round_trip.spec.js does:
// the session is set by hand below, so the real endpoint would answer 401 and
// the trip would end at the sign-in card instead of the wallet. `delayMs` holds
// prepare open, which is what "while redirect prepare is active" means — the
// window in which another beat can land a card on top of this flow's.
async function stubPrepare(context, { delayMs = 0 } = {}) {
  const seen = { confirmed: false };
  await context.route("**/contests/*/prepare_entry", async (route) => {
    if (delayMs) await new Promise((resolve) => setTimeout(resolve, delayMs));
    await route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        success: true,
        serialized_tx: "AQIDBAU=",
        ptx_slug: "ptx-stub-1",
        entry_id: 4242,
        entry_pda: "EntryPdaStub111111111111111111111111111111",
        token_funded: true,
      }),
    });
  });
  await context.route("**/contests/*/confirm_onchain_entry", (route) => {
    seen.confirmed = true;
    return route.abort();
  });
  return seen;
}

async function openBoard(page) {
  await page.goto(BOARD_CONTEST);
  await page.waitForFunction(
    () => !!(document.querySelector(".hold-btn") && window.Alpine && window.tmWalletOp &&
             window.SolanaStudio && window.SolanaStudio.walletOps &&
             window.SolanaStudio.walletOps.defined("contest_entry"))
  );
}

// THE CABLE (reason 3 in the header), and the order is the whole trick. Action
// Cable's close() only closes a socket that is already OPEN — on one still
// connecting it does nothing, and the socket opens a moment later. A cold
// server made exactly that happen once: the restore was refused with
// "websocket" and this spec's first guard said so. So: wait for OPEN, then
// disconnect, then wait for CLOSED.
async function closeCable(page) {
  const cableState = () =>
    page.evaluate(() => {
      const source = document.querySelector("turbo-cable-stream-source");
      if (!source) return "none";
      if (!source.subscription) return "pending";
      return source.subscription.consumer.connection.getState();
    });
  await expect.poll(cableState).toMatch(/^(open|none)$/);
  await page.evaluate(() => {
    const source = document.querySelector("turbo-cable-stream-source");
    if (source) source.subscription.consumer.disconnect();
  });
  await expect.poll(cableState).toMatch(/^(closed|none)$/);
}

// THE SESSION IS SET BY HAND, and only the session — the same move
// e2e/stub_wallet_round_trip.spec.js makes, for the same reason: a web3 sign-in
// on this lane goes through the injected Phantom mock, which hands the board an
// INLINE provider and never reaches this transport. Everything from
// confirmEntry() onward is the app's own. Returns the marker left on this
// document, and arms the two logs each test reads to prove its mechanism.
async function startEntry(page) {
  return page.evaluate(() => {
    window.__handoffMarker = "doc-" + Math.random().toString(36).slice(2);
    window.__pageshows = [];
    window.__visibility = [];
    window.addEventListener("pageshow", (e) => window.__pageshows.push(e.persisted));
    document.addEventListener("visibilitychange", () =>
      window.__visibility.push(document.hidden ? "hidden" : "visible")
    );

    const s = Alpine.store("session");
    s.loggedIn = true;
    s.mode = "web3";
    s.address = "";
    s.firstNameRequired = false;
    s.ageGateRequired = false;
    s.walletSetupRequired = false;
    s.tokensAvailable = 1;
    const board = Alpine.$data(document.querySelector(".hold-btn").closest("[x-data]"));
    board.contestOnchain = true;
    // Off this evaluate's stack: the page is about to be handed to the wallet.
    setTimeout(() => board.confirmEntry(), 0);
    return window.__handoffMarker;
  });
}

const modalIds = (page) => page.evaluate(() => Alpine.store("modals").stack.map((e) => e.id));

const boardSubmitting = (page) =>
  page.evaluate(() => Alpine.$data(document.querySelector(".hold-btn").closest("[x-data]")).submitting);

// A REAL WHEEL, not scrollTo: programmatic scrolling moves even an
// overflow:hidden root, so it cannot tell a locked page from a free one.
async function scrollsUnderAWheel(page) {
  const viewport = page.viewportSize();
  await page.mouse.move(viewport.width / 2, viewport.height / 2);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.mouse.wheel(0, 600);
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBeGreaterThan(0);
}

test("a swipe back from an unanswered wallet handoff returns a live, scrollable board", async ({ page, context }) => {
  // The wallet receives the trip, judges it, and then the user walks away.
  const wallet = await installStubWallet(context, { answer: () => ({ abandon: true }) });
  const seen = await stubPrepare(context);

  await openBoard(page);
  await closeCable(page);
  const marker = await startEntry(page);

  // THE WALLET TOOK THE SCREEN, and the request it got was one Phantom accepts.
  await page.waitForURL((url) => url.hostname === "phantom.app", { timeout: 15_000 });
  await expect(page.locator("[data-stub-wallet-abandoned]")).toBeVisible();
  expect(wallet.methods()).toEqual(["connect"]);
  expect(wallet.violations).toEqual([]);

  // THE SWIPE BACK. "commit" on both waits, because a restore fires no load
  // event of its own — waiting for one hangs on exactly the path under test.
  await page.goBack({ waitUntil: "commit" });
  await page.waitForURL((url) => url.pathname === BOARD_CONTEST, { waitUntil: "commit" });

  // 1. FIRST, THE RESTORE WAS REAL.
  const restore = await page.evaluate(() => {
    const nav = performance.getEntriesByType("navigation")[0];
    return {
      marker: window.__handoffMarker || null,
      pageshows: window.__pageshows || null,
      notRestoredReasons: nav && nav.notRestoredReasons ? JSON.parse(JSON.stringify(nav.notRestoredReasons)) : null,
    };
  });
  expect(
    restore.marker,
    "the board came back as a FRESH document, not out of the bfcache, so this run " +
      "cannot see the trap. Chrome's notRestoredReasons: " + JSON.stringify(restore.notRestoredReasons)
  ).toBe(marker);
  expect(restore.pageshows, "the restored document logged no persisted pageshow").toContain(true);

  // 2. THE ONE RIGHT ANSWER. The card is gone and the page scrolls.
  //    THE DIALOG, NOT ITS COPY. By the time the user leaves, the entry intent
  //    has re-titled the card ("Sign Transaction"), so a text match on the
  //    runner's "Opening Your Wallet" passes with the trap fully intact —
  //    measured, on the control run. The host mounts its role="dialog"
  //    backdrop through x-if, so it is absent exactly when no card is up.
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect.poll(() => page.evaluate(() => Alpine.store("modals").stack.length)).toBe(0);
  await expect(page.locator("body")).not.toHaveClass(/modal-open/);
  expect(await page.evaluate(() => getComputedStyle(document.documentElement).overflowY)).not.toBe("hidden");
  await scrollsUnderAWheel(page);

  // 3. AND THE BOARD HANDED ITS CONTROLS BACK, so the retry the user came back
  //    for is not refused. submitting is the flag confirmEntry guards on.
  expect(await boardSubmitting(page)).toBe(false);
  // Retiring the card decided nothing on the server's behalf.
  expect(seen.confirmed).toBe(false);
});

test("a celebration stacked over the handoff leaves no frozen card underneath", async ({ page, context }) => {
  // Longer than the file default: this one deliberately holds prepare open
  // while the level-up beat (dispatch + its own 900ms) lands a card on top.
  test.setTimeout(60_000);
  // THE COMPOSED RETURN (review of PR 697). Two cards, one way back, and the
  // one that matters is the one the user cannot see.
  const wallet = await installStubWallet(context, { answer: () => ({ stayPut: true }) });
  // Prepare is held open long enough for the level-up beat — dispatch plus its
  // own 900ms delay — to land its card while this flow is still preparing.
  const seen = await stubPrepare(context, { delayMs: 4_000 });

  await openBoard(page);
  // No cable close here: this way back never leaves the document, so the
  // bfcache — and studio-engine's pageshow cleanup with it — is not in play.
  // That is the point of the composition: nothing else is going to drop the
  // celebration for us.
  await startEntry(page);

  // 1. THE PROCESSING CARD IS UP, still waiting on prepare.
  await expect.poll(() => modalIds(page)).toEqual(["onchain-tx"]);

  // 2. THE CELEBRATION LANDS ON TOP OF IT, through the app's own beat: the
  //    layout listens for navbar-seeds-update with levelUp and, finding a card
  //    that forbids dismissal, opens rather than swaps.
  await page.evaluate(() =>
    window.dispatchEvent(new CustomEvent("navbar-seeds-update", { detail: { levelUp: true, newLevel: 2 } }))
  );
  await expect.poll(() => modalIds(page), { timeout: 10_000 }).toEqual(["onchain-tx", "free-entry-earned"]);

  // 3. THE OS TAKES THE LINK. The stub aborts the navigation, which is what a
  //    universal link does to the browser when the wallet app answers it: this
  //    document stays alive, behind the wallet.
  await expect.poll(() => wallet.methods(), { timeout: 15_000 }).toEqual(["connect"]);
  expect(wallet.violations).toEqual([]);
  expect(new URL(page.url()).pathname, "the document must not have been replaced").toBe(BOARD_CONTEST);

  // 4. THE APP SWITCH, AND THE WAY BACK — and here is the ONE simulated step in
  //    this file, named rather than buried. HEADLESS CHROMIUM KEEPS EVERY PAGE
  //    VISIBLE: measured 2026-09-13, `document.visibilityState` stayed "visible"
  //    through another page's bringToFront(), through Target.activateTarget on
  //    that page, and through Page.setWebLifecycleState "frozen" — no
  //    visibilitychange fired at all. So the page's own visibility is overridden
  //    here and the event is DISPATCHED. Everything it reaches is real: the
  //    handler the runner armed, the store, the host, and the two cards that a
  //    real handoff and the app's own level-up beat put on the stack. What it
  //    does not prove is that a phone fires visibilitychange on an app switch —
  //    /tasks/verify-wallets-on-a-phone carries that, and the bfcache test above
  //    needs no simulation at all.
  const setVisibility = (state) =>
    page.evaluate((value) => {
      Object.defineProperty(document, "visibilityState", { configurable: true, get: () => value });
      Object.defineProperty(document, "hidden", { configurable: true, get: () => value === "hidden" });
      document.dispatchEvent(new Event("visibilitychange"));
    }, state);

  await setVisibility("hidden");
  expect(await page.evaluate(() => document.hidden), "the override did not take").toBe(true);
  await setVisibility("visible");

  // The document was never restored — it is the same one throughout, and no
  // pageshow carried persisted, so nothing here rides the bfcache path.
  const observed = await page.evaluate(() => ({
    visibility: window.__visibility,
    pageshows: window.__pageshows,
    marker: window.__handoffMarker,
  }));
  expect(observed.visibility.slice(-2), "the page never went hidden and came back").toEqual(["hidden", "visible"]);
  expect(observed.pageshows, "this way back restores nothing, so no pageshow may carry persisted").not.toContain(true);
  expect(observed.marker).toBeTruthy();

  // 5. THE BURIED CARD IS GONE, and the celebration the user was reading is not.
  await expect.poll(() => modalIds(page)).toEqual(["free-entry-earned"]);
  await expect(page.getByRole("dialog")).toHaveCount(1);
  // Still locked, and still correctly so: a card is up.
  await expect(page.locator("body")).toHaveClass(/modal-open/);

  // 6. AND WHEN THE CELEBRATION CLOSES, the page is free — no frozen card
  //    underneath it, no scroll lock left behind. This is the assertion the
  //    current-only reader failed: it left the transaction card on the stack,
  //    so closing the celebration revealed it again.
  await page.evaluate(() => Alpine.store("modals").close());
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.locator("body")).not.toHaveClass(/modal-open/);
  expect(await page.evaluate(() => getComputedStyle(document.documentElement).overflowY)).not.toBe("hidden");
  await scrollsUnderAWheel(page);

  expect(await boardSubmitting(page)).toBe(false);
  expect(seen.confirmed).toBe(false);
});

// A CARD IN ONE OF THE STORE'S OWN ENTRIES, read off the stack rather than off
// the screen: the buried one is not visible, and "which card, in what state" is
// what both tests below are actually about.
const cardState = (page, id) =>
  page.evaluate((wanted) => {
    const entry = Alpine.store("modals").stack.find((e) => e.id === wanted);
    return entry ? [entry.id, entry.props.state, entry.props.dismissible] : null;
  }, id);

test("a hop that never happens is answered on the card a celebration buried", async ({ page, context }) => {
  // Longer than the file default: the celebration beat costs a dispatch plus its
  // own 900ms, and the grace window is 2500ms after prepare resolves.
  test.setTimeout(60_000);
  // THE STRANDED LEG, COMPOSED (/tasks/stranded-handoff-buries-card). Same
  // stack as the test above, different ending: nobody takes the link, so this
  // page is still here — visible — when the grace window fires. The card that
  // has to answer is the one under the celebration.
  const wallet = await installStubWallet(context, { answer: () => ({ stayPut: true }) });
  const seen = await stubPrepare(context, { delayMs: 4_000 });

  await openBoard(page);
  await startEntry(page);
  await expect.poll(() => modalIds(page)).toEqual(["onchain-tx"]);

  // The app's own level-up beat lands its card on top of one that forbids
  // dismissal, rather than swapping it away.
  await page.evaluate(() =>
    window.dispatchEvent(new CustomEvent("navbar-seeds-update", { detail: { levelUp: true, newLevel: 2 } }))
  );
  await expect.poll(() => modalIds(page), { timeout: 10_000 }).toEqual(["onchain-tx", "free-entry-earned"]);

  // The link is handed over and NOTHING takes it: the navigation never commits,
  // this document stays, and — unlike the app-switch test — it stays VISIBLE.
  await expect.poll(() => wallet.methods(), { timeout: 15_000 }).toEqual(["connect"]);
  expect(wallet.violations).toEqual([]);
  expect(new URL(page.url()).pathname, "the document must not have been replaced").toBe(BOARD_CONTEST);
  expect(await page.evaluate(() => document.visibilityState),
    "nothing switched away here — that is the other test").toBe("visible");

  // 1. THE BURIED CARD ANSWERS, on the grace window. Read off the stack,
  //    because nothing about it is on screen: it is still the first entry, it
  //    is no longer processing, and it is now something the user can close.
  await expect
    .poll(() => cardState(page, "onchain-tx"), { timeout: 15_000 })
    .toEqual(["onchain-tx", "error", true]);
  await expect.poll(() => modalIds(page)).toEqual(["onchain-tx", "free-entry-earned"]);
  expect(await boardSubmitting(page)).toBe(false);

  // 2. THE USER CLOSES THE CELEBRATION and meets that answer instead of a
  //    frozen spinner. This is the acceptance the old leg failed: it said
  //    nothing at all, and what surfaced here was a non-dismissible card.
  await page.evaluate(() => Alpine.store("modals").close());
  await expect.poll(() => modalIds(page)).toEqual(["onchain-tx"]);
  await expect(page.getByRole("dialog")).toHaveCount(1);
  await expect(page.getByRole("dialog")).toContainText("Wallet Did Not Open");

  // 3. AND THEY CAN LEAVE, through the card's own button — no store call, the
  //    control a thumb can reach.
  await page.getByRole("dialog").getByRole("button", { name: "Close" }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.locator("body")).not.toHaveClass(/modal-open/);
  expect(await page.evaluate(() => getComputedStyle(document.documentElement).overflowY)).not.toBe("hidden");
  await scrollsUnderAWheel(page);

  expect(seen.confirmed).toBe(false);
});

test("a hop that never happens still says so on the card in front of the user", async ({ page, context }) => {
  // THE VISIBLE CASE, WHICH MUST NOT GO QUIET. Reaching the buried card is only
  // half the acceptance: this is the case "Wallet Did Not Open" was written for,
  // and a fix that bought the buried one by dropping this sentence would be a
  // worse bug than the one it closed. Same leg, no celebration.
  const wallet = await installStubWallet(context, { answer: () => ({ stayPut: true }) });
  const seen = await stubPrepare(context);

  await openBoard(page);
  await startEntry(page);
  await expect.poll(() => wallet.methods(), { timeout: 15_000 }).toEqual(["connect"]);
  expect(wallet.violations).toEqual([]);

  await expect
    .poll(() => cardState(page, "onchain-tx"), { timeout: 15_000 })
    .toEqual(["onchain-tx", "error", true]);
  await expect(page.getByRole("dialog")).toHaveCount(1);
  await expect(page.getByRole("dialog")).toContainText("Wallet Did Not Open");
  await expect(page.getByRole("dialog")).toContainText("Make sure it is installed on this device");

  await page.getByRole("dialog").getByRole("button", { name: "Close" }).click();
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect(page.locator("body")).not.toHaveClass(/modal-open/);
  await scrollsUnderAWheel(page);

  expect(await boardSubmitting(page)).toBe(false);
  expect(seen.confirmed).toBe(false);
});
