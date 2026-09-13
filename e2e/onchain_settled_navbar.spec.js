const { test, expect } = require("@playwright/test");
const { loginViaPhantom } = require("./helpers");
const { setupPhantomMock } = require("./phantom-mock");

// THE SETTLE WINDOW, IN A REAL BROWSER (task: onchain-success-reloads-state).
//
// WHY THIS FILE HAS TO EXIST. The unit coverage for onchainSettled() executes
// solana_utils.js in NODE, against stubbed globals. That proves the module's
// logic and nothing about the PAGE: not that the layout calls
// settleOnLoadIfPending(), not that the importmap serves the module, not that
// the pill it paints is the element the navbar actually renders. Every one of
// those is a place the feature can be perfectly correct and still not run.
//
// So this asserts things only a live browser can produce: the DOM state of the
// real [data-balance-display] element, and the real number of
// /account/session_refresh requests the page issues.
//
// The bug being pinned: a read taken right after a spend can return the
// PRE-SPEND balance, because the RPC has not caught up. Measured on QA
// 2026-09-07 — a $75 contest creation, a refresh 828ms after the server
// answered, and a navbar that showed the old number for the next minute.

const SETTLE_KEY = "tm:onchain-settle-until";
const SETTLED = "1164.0";
const PILL = "[data-balance-display]";

// Serve a KNOWN settled balance and count every read the page makes.
async function stubSessionRefresh(page, counter) {
  await page.route("**/account/session_refresh", (route) => {
    counter.count += 1;
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        usdc: SETTLED, usdt: "0.0", tokens: "0",
        seeds: 0, level: 1, toward_next: 0, progress: 0
      })
    });
  });
}

test.describe("on-chain settle window", () => {
  test.beforeEach(async ({ page }) => {
    await setupPhantomMock(page);
    await loginViaPhantom(page);
  });

  test("a pending settle holds the pill in loading, then paints once", async ({ page }) => {
    const reads = { count: 0 };
    await stubSessionRefresh(page, reads);

    // Arrange the state a navigating caller leaves behind. Written through the
    // page's own sessionStorage — the same store onchainSettled writes — rather
    // than by calling the function, so this exercises the HANDOFF and not just
    // the writer.
    await page.evaluate(
      ([key, until]) => window.sessionStorage.setItem(key, String(until)),
      [SETTLE_KEY, Date.now() + 4000]
    );

    const readsBeforeReload = reads.count;
    await page.reload();

    // DURING THE WINDOW — the assertion that matters. The page has loaded and
    // the layout ran, and it must NOT have read the chain, and must NOT be
    // showing a dollar figure. A String assertion cannot see either of these.
    await page.waitForTimeout(1200);
    const pill = page.locator(PILL).first();
    await expect(pill).toHaveClass(/hidden/);
    expect((await pill.textContent()).trim()).toBe("");
    expect(reads.count).toBe(readsBeforeReload);

    // AFTER — exactly one read, and the settled number on screen.
    await expect(pill).not.toHaveClass(/hidden/, { timeout: 15000 });
    await expect(pill).toHaveText(/^\$1164$/, { timeout: 15000 });
    expect(reads.count).toBe(readsBeforeReload + 1);
  });

  // ONE WRITER, IN A BROWSER. The level-up token poller calls the same
  // refreshSession() inside the settle window; review measured ~7.6s of the
  // PRE-SPEND figure presented as the answer. The stub here deliberately serves
  // the PRE-SPEND number so a too-early paint is visible — a fixture that
  // answered 1164 to everyone could not express this bug, which is how the
  // first version of this file missed it.
  test("a competing refresh cannot paint the balance mid-window", async ({ page }) => {
    await page.route("**/account/session_refresh", (route) =>
      route.fulfill({
        status: 200, contentType: "application/json",
        body: JSON.stringify({ usdc: "1239.0", usdt: "0.0", tokens: "0", seeds: 0, level: 1, toward_next: 0, progress: 0 })
      })
    );

    await page.evaluate(
      ([key, until]) => window.sessionStorage.setItem(key, String(until)),
      [SETTLE_KEY, Date.now() + 6000]
    );
    await page.reload();
    await page.waitForTimeout(1000);

    // Drive the competing read the poller would make, through the real module.
    await page.evaluate(() => window.refreshSession && window.refreshSession());
    await page.waitForTimeout(600);

    const pill = page.locator(PILL).first();
    await expect(pill).toHaveClass(/hidden/);
    expect((await pill.textContent()).trim()).toBe("");
  });

  test("a normal load with no pending settle hydrates immediately", async ({ page }) => {
    const reads = { count: 0 };
    await stubSessionRefresh(page, reads);

    // THE CONTROL. Without it, a settleOnLoadIfPending() that always returned
    // true would pass the test above while silently breaking every ordinary
    // page load — the navbar would simply never hydrate.
    await page.evaluate((key) => window.sessionStorage.removeItem(key), SETTLE_KEY);
    const before = reads.count;
    await page.reload();

    await expect(page.locator(PILL).first()).toHaveText(/^\$1164$/, { timeout: 15000 });
    expect(reads.count).toBeGreaterThan(before);
  });

  // ── THE STAY-PUT-BUT-MAY-NAVIGATE CALLER (survivor-settle-never-fires) ────
  //
  // WHY THESE ARE HERE AND NOT ONLY IN NODE. test/lib/onchain_settled_js_test.rb
  // executes the same module against stubbed globals and proves the logic. It
  // cannot prove the importmap serves the new branch, that window.onchainSettled
  // accepts the option on a real page, or that the element it blanks is the pill
  // the navbar renders. The survivor board's call is guarded by
  // `typeof onchainSettled === 'function'`, so every one of those failures is
  // SILENT — which is the same shape as the bug this task fixes.
  //
  // THE BUG. The survivor board called onchainSettled({ navigating: true }) on
  // the belief that its success card auto-redirects. It does not: it sets no
  // lobbyUrl, so the engine's startCountdown() returns early and no countdown is
  // armed. The marker was written for a navigation that never came, nothing was
  // scheduled, and the navbar held the PRE-SPEND figure for as long as the card
  // stayed open. The user leaves that card by CLOSING it, and modal.onClose
  // assigns window.location — which would destroy a bare timer. So the surface
  // needs both halves, which is what mayNavigate means.
  //
  // NOTE THE VOID ARROW in every call below. onchainSettled() returns a Promise
  // on this branch, and page.evaluate AWAITS a returned promise — so returning it
  // would silently park the test until the settle had already finished, and the
  // during-the-window assertions would all read post-settle state.

  test("a mayNavigate caller arms BOTH halves and settles in place", async ({ page }) => {
    const reads = { count: 0 };
    await stubSessionRefresh(page, reads);
    await page.evaluate((key) => window.sessionStorage.removeItem(key), SETTLE_KEY);
    await page.waitForTimeout(1200);          // let the ordinary load-time hydrate finish
    const before = reads.count;

    await page.evaluate(() => { window.onchainSettled({ mayNavigate: true, delayMs: 4000 }); });

    // ON THE SPEND — the half that was missing. A marker-only caller never
    // blanked the pill at all, which is how the pre-spend figure stayed up.
    const pill = page.locator(PILL).first();
    await expect(pill).toHaveClass(/hidden/);
    expect((await pill.textContent()).trim()).toBe("");

    // AND THE MARKER, IN THE SAME BREATH. This assertion is what makes the test
    // discriminate, and it was missing. An unknown option falls through to a
    // plain schedule, so every assertion above passes against a module that has
    // never heard of mayNavigate — the test would have been green on the very
    // bug it was written for. Both halves armed at once is the thing neither
    // other shape can do: navigating leaves the marker and schedules nothing,
    // stay-put schedules and leaves no marker.
    expect(
      await page.evaluate((key) => window.sessionStorage.getItem(key), SETTLE_KEY)
    ).not.toBeNull();

    await page.waitForTimeout(1500);
    expect(reads.count).toBe(before);          // and no read inside the window

    // AFTER — it settles IN PLACE, with no navigation anywhere in this test.
    await expect(pill).not.toHaveClass(/hidden/, { timeout: 15000 });
    await expect(pill).toHaveText(/^\$1164$/, { timeout: 15000 });
    expect(reads.count).toBe(before + 1);
  });

  test("a mayNavigate settle survives a close-triggered navigation", async ({ page }) => {
    const reads = { count: 0 };
    await stubSessionRefresh(page, reads);
    await page.evaluate((key) => window.sessionStorage.removeItem(key), SETTLE_KEY);
    await page.waitForTimeout(1200);

    await page.evaluate(() => { window.onchainSettled({ mayNavigate: true, delayMs: 9000 }); });

    // The marker is written even though this caller also scheduled — that is the
    // half the close destroys, and closing is how people leave this card.
    const marker = await page.evaluate((key) => window.sessionStorage.getItem(key), SETTLE_KEY);
    expect(marker).not.toBeNull();

    const beforeNav = reads.count;
    await page.reload();                       // modal.onClose assigns window.location

    // The destination INHERITS the remaining window: still loading, still no read.
    const pill = page.locator(PILL).first();
    await page.waitForTimeout(1500);
    await expect(pill).toHaveClass(/hidden/);
    expect((await pill.textContent()).trim()).toBe("");
    expect(reads.count).toBe(beforeNav);

    // ...and settles there. The settle was not lost by leaving.
    await expect(pill).toHaveText(/^\$1164$/, { timeout: 20000 });
    expect(reads.count).toBe(beforeNav + 1);
  });

  // THE RETIRE IS SCOPED TO THE WINDOW IT SERVED (review of PR #645).
  //
  // The first version of this test asserted only that the marker was null after
  // a settle, which a module that never wrote one passes trivially — it proved
  // nothing. Worse, the implementation it was guarding retired the KEY, so a
  // read finishing for spend #1 deleted spend #2's marker and spend #2 then
  // settled nowhere: the navbar painted its PRE-SPEND balance with .hidden
  // cleared, presented as the answer, and nothing corrected it.
  //
  // So this drives the two-spend sequence in a real browser. The deferred read
  // is made the way a destination page makes one — settleOnLoadIfPending
  // consumes the marker on the way in, so that settle owns none — and a second
  // spend arms its own while the first read is still in flight.
  test("a landed read retires only the window it served", async ({ page }) => {
    const reads = { count: 0 };
    await stubSessionRefresh(page, reads);
    await page.evaluate((key) => window.sessionStorage.removeItem(key), SETTLE_KEY);
    await page.waitForTimeout(1200);
    const before = reads.count;

    // Spend #1, inherited. Its marker is consumed here, so this settle owns none.
    await page.evaluate(
      ([key, until]) => {
        window.sessionStorage.setItem(key, String(until));
        window.settleOnLoadIfPending();
      },
      [SETTLE_KEY, Date.now() + 3000]
    );

    // Spend #2 lands on the same page while spend #1's read is still pending.
    // Its window is long, so nothing but the retire can end it inside this test.
    await page.evaluate(() => { window.onchainSettled({ mayNavigate: true, delayMs: 20000 }); });
    const markerOfSpend2 = await page.evaluate((key) => window.sessionStorage.getItem(key), SETTLE_KEY);
    expect(markerOfSpend2).not.toBeNull();

    // Spend #1's read lands and paints...
    await expect(page.locator(PILL).first()).toHaveText(/^\$1164$/, { timeout: 15000 });
    expect(reads.count).toBe(before + 1);

    // ...and must not have taken spend #2's window with it. Against real
    // sessionStorage, after the real module ran a real fetch.
    const markerAfter = await page.evaluate((key) => window.sessionStorage.getItem(key), SETTLE_KEY);
    expect(markerAfter).toBe(markerOfSpend2);

    // Which is what lets the page the user lands on still inherit that window,
    // instead of hydrating normally and reading the chain early.
    const beforeNav = reads.count;
    await page.reload();
    const pill = page.locator(PILL).first();
    await page.waitForTimeout(1500);
    await expect(pill).toHaveClass(/hidden/);
    expect(reads.count).toBe(beforeNav);
  });
});
