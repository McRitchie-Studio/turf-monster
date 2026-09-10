// THE WAY BACK FROM A WALLET THAT NEVER ANSWERED — through a REAL bfcache restore.
//
// /tasks/frozen-wallet-overlay-traps-user. The trap, in the order a phone walks
// it: the user holds to enter, the NON-DISMISSIBLE processing card paints
// "Opening Your Wallet", the wallet takes the screen, and the user changes their
// mind and goes back without acting. The page comes back out of the
// back/forward cache exactly as it left — card up, body scroll-locked by
// `html:has(body.modal-open) { overflow: hidden }` (which also kills
// pull-to-refresh) — and before this fix nothing was left watching, so the
// user was stuck until they closed the tab.
//
// WHY THIS FILE LAUNCHES ITS OWN BROWSER. Three things stood between this lane
// and a real restore, each measured with CDP's Page.backForwardCacheNotUsed:
//
//   1. THE SWITCH. Playwright starts Chromium with --disable-back-forward-cache
//      (playwright-core 1.58.2, lib/server/chromium/chromiumSwitches.js:59), so
//      every other page.goBack() in this suite is a fresh load or a Turbo
//      restore. `ignoreDefaultArgs` drops that one switch.
//   2. THE SHELL. Even without the switch, the default headless shell refuses
//      every page, a static one included — BackForwardCacheDisabledForDelegate,
//      which the page itself sees only as "masked". channel "chromium" runs the
//      full build in new headless mode, which caches. `playwright install
//      chromium` in CI installs both builds.
//   3. THE CABLE. The board holds turbo's Action Cable socket open, and Chromium
//      will not cache a page with a live WebSocket (reason "WebSocket",
//      SupportPending). So the spec closes that socket before the handoff. It
//      makes the page ELIGIBLE and changes nothing the restore brings back —
//      the card, the scroll lock and the board's state are untouched.
//
// All three are worker options, so this file gets a worker of its own and
// nothing else in the lane changes.
//
// AND WHY IT PROVES THE RESTORE BEFORE IT PROVES THE FIX. A green run reached
// by a fresh load would be the wrong path to a right-looking answer: a new
// document has no card at all. So the spec first shows the SAME document came
// back (a marker left on window before the trip survives, and that document
// logged a pageshow with persisted === true). If Chrome ever refuses the
// restore, the assertion message carries its notRestoredReasons.
//
// WHAT THIS CANNOT SEE, said plainly: this is Chromium with an iPhone user
// agent, not iOS WebKit. It proves the handler and a genuine bfcache restore;
// it does not prove Safari's restore — whether Safari caches this board with
// its cable open is not measurable here, because Playwright's WebKit restored
// not even a static page from its cache — and it does not drive the other way
// back the runner watches for: an app switch that never unloads the page, which
// is a visibilitychange rather than a restore (test/lib/wallet_op_runner_js_test.rb
// drives that one). Only a phone proves either on iOS.
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

test("a swipe back from an unanswered wallet handoff returns a live, scrollable board", async ({ page, context }) => {
  // The wallet receives the trip, judges it, and then the user walks away.
  const wallet = await installStubWallet(context, { answer: () => ({ abandon: true }) });

  // Stub ONLY the server's prepare, as e2e/stub_wallet_round_trip.spec.js does:
  // the session below is set by hand, so the real endpoint would answer 401 and
  // the trip would end at the sign-in card instead of the wallet. Nothing is
  // ever confirmed — the user never answers.
  let confirmed = false;
  await context.route("**/contests/*/prepare_entry", (route) =>
    route.fulfill({
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
    })
  );
  await context.route("**/contests/*/confirm_onchain_entry", (route) => {
    confirmed = true;
    return route.abort();
  });

  await page.goto(BOARD_CONTEST);
  await page.waitForFunction(
    () => !!(document.querySelector(".hold-btn") && window.Alpine && window.tmWalletOp &&
             window.SolanaStudio && window.SolanaStudio.walletOps &&
             window.SolanaStudio.walletOps.defined("contest_entry"))
  );

  // THE CABLE (reason 3 in the header), and the order is the whole trick.
  // Action Cable's close() only closes a socket that is already OPEN — on one
  // still connecting it does nothing, and the socket opens a moment later. A
  // cold server made exactly that happen once: the restore was refused with
  // "websocket" and this spec's first guard said so. So: wait for OPEN, then
  // disconnect, then wait for CLOSED.
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

  // THE SESSION IS SET BY HAND, and only the session — the same move
  // e2e/stub_wallet_round_trip.spec.js makes, for the same reason: a web3
  // sign-in on this lane goes through the injected Phantom mock, which hands
  // the board an INLINE provider and never reaches this transport. Everything
  // from confirmEntry() onward is the app's own.
  const marker = await page.evaluate(() => {
    // Left on THIS document. A bfcache restore brings the same heap back; a
    // fresh load starts a new one without it.
    window.__handoffMarker = "doc-" + Math.random().toString(36).slice(2);
    window.__pageshows = [];
    window.addEventListener("pageshow", (e) => window.__pageshows.push(e.persisted));

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

  // 2. THE ONE RIGHT ANSWER. The card is gone, and the page scrolls under a
  //    real wheel — a programmatic scrollTo would move even an overflow:hidden
  //    root, so it cannot tell a locked page from a free one.
  //    THE DIALOG, NOT ITS COPY. By the time the user leaves, the entry intent
  //    has re-titled the card ("Sign Transaction"), so a text match on the
  //    runner's "Opening Your Wallet" passes with the trap fully intact —
  //    measured, on the control run. The host mounts its role="dialog"
  //    backdrop through x-if, so it is absent exactly when no card is up.
  await expect(page.getByRole("dialog")).toHaveCount(0);
  await expect.poll(() => page.evaluate(() => Alpine.store("modals").stack.length)).toBe(0);
  await expect(page.locator("body")).not.toHaveClass(/modal-open/);
  expect(await page.evaluate(() => getComputedStyle(document.documentElement).overflowY)).not.toBe("hidden");

  const viewport = page.viewportSize();
  await page.mouse.move(viewport.width / 2, viewport.height / 2);
  await page.evaluate(() => window.scrollTo(0, 0));
  await page.mouse.wheel(0, 600);
  await expect.poll(() => page.evaluate(() => window.scrollY)).toBeGreaterThan(0);

  // 3. AND THE BOARD HANDED ITS CONTROLS BACK, so the retry the user came back
  //    for is not refused. submitting is the flag confirmEntry guards on.
  expect(
    await page.evaluate(() => Alpine.$data(document.querySelector(".hold-btn").closest("[x-data]")).submitting)
  ).toBe(false);
  // Retiring the card decided nothing on the server's behalf.
  expect(confirmed).toBe(false);
});
