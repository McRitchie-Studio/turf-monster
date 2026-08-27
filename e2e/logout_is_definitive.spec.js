const { test, expect } = require("@playwright/test");
const { loginViaPhantom, reseed } = require("./helpers");
const { setupPhantomMock } = require("./phantom-mock");

test.beforeEach(async ({ request }) => await reseed(request));

// REQUIREMENT 6 — "Logout is a start-from-scratch button and should behave like one."
//
// It did not. The only client-side clearing was an inline onclick, duplicated in
// two views, removing ONE key of nineteen; server-side, two hand-maintained
// deny-lists that could not see each other leaked seven session keys between
// them. This spec is the whole-browser version of that claim, which neither the
// unit nor the integration tier can make: it drives a real logout and then looks
// at what is actually left in the browser.

test("logout empties the browser except the device preferences", async ({ page }) => {
  await setupPhantomMock(page, { walletStandard: false });
  await loginViaPhantom(page);
  await page.goto("/account");

  // Dirty the browser the way a real session does, and set a device preference
  // so the SURVIVOR half of the contract is tested too — a wipe that takes
  // everything is as wrong as one that takes nothing.
  await page.evaluate(() => {
    localStorage.setItem("theme", "light");
    localStorage.setItem("inviter_slug", "someone");
    localStorage.setItem("seedsNavbar", JSON.stringify({ seeds_total: 40, level: 1 }));
    localStorage.setItem("phantom_dl_secret", "leaked-secret");
    localStorage.setItem("pendingContestEntry", JSON.stringify({ contestSlug: "x" }));
    sessionStorage.setItem("pendingAuthStep", "buy-tokens");
    sessionStorage.setItem("walletSetupReopen", "1");
  });

  // `:visible` matters — /account renders TWO logout links and the gear
  // sidebar's lives in a collapsed panel. `.first()` picks that hidden one and
  // the click times out, which reads like a broken logout rather than a
  // mis-aimed selector.
  await page.locator(`a[href="/logout"]:visible`).first().click();
  await page.waitForURL(/\/signin/);

  const after = await page.evaluate(() => ({
    local: Object.fromEntries(Object.entries(localStorage)),
    session: Object.fromEntries(Object.entries(sessionStorage))
  }));

  expect(after.local).toEqual({ theme: "light" });
  expect(after.session).toEqual({});
});

test("a second user inherits nothing from the first", async ({ page }) => {
  await setupPhantomMock(page, { walletStandard: false });
  await loginViaPhantom(page);
  await page.goto("/account");

  const firstUserId = await page.locator("body").getAttribute("data-user-id");
  await page.evaluate(() => {
    localStorage.setItem("seedsNavbar", JSON.stringify({ seeds_total: 999, level: 10 }));
    localStorage.setItem("phantom_dl_pubkey", "first-users-wallet");
  });

  // `:visible` matters — /account renders TWO logout links and the gear
  // sidebar's lives in a collapsed panel. `.first()` picks that hidden one and
  // the click times out, which reads like a broken logout rather than a
  // mis-aimed selector.
  await page.locator(`a[href="/logout"]:visible`).first().click();
  await page.waitForURL(/\/signin/);

  // A DIFFERENT wallet signs in on the same browser.
  await page.evaluate(() => window.phantom.solana.__switchAccount(7, { emitEvent: false }));
  await loginViaPhantom(page);
  await page.goto("/account");

  const secondUserId = await page.locator("body").getAttribute("data-user-id");
  expect(secondUserId).not.toBe(firstUserId);

  // The first user's cached seeds and deeplink handshake must be gone. Before
  // this slice they were swept only by the layout's lastUserId check on the NEXT
  // render — a different mechanism doing logout's job late.
  const leaked = await page.evaluate(() => ({
    seeds: localStorage.getItem("seedsNavbar"),
    pubkey: localStorage.getItem("phantom_dl_pubkey")
  }));
  expect(leaked.pubkey).toBeNull();
  expect(leaked.seeds === null || !leaked.seeds.includes("999")).toBe(true);
});

// THE RECEIVE HALF, which had no test anywhere until now.
//
// session_wipe.js has two halves. The SEND half posts {type:"logout-wipe"} on the
// "tm-session" BroadcastChannel when this tab logs out — that half is covered, and
// mutation M9 reddened when the broadcast was removed. The RECEIVE half is the
// listener that wipes THIS tab when a PEER logs out, and mutation M10 deleted it
// outright while the ENTIRE SUITE STAYED GREEN at every tier.
//
// The reason is structural rather than an oversight: no spec had ever opened a
// SECOND tab, so nothing could observe a cross-tab message. A BroadcastChannel is
// scoped to an origin within one browser context, so both pages must live in the
// SAME context — two `page` fixtures would be two contexts and would never hear
// each other, which is a way to write this test that passes for the wrong reason.
//
// ONE CONTEXT IS ALSO ONE localStorage — it is origin-scoped and SHARED across
// tabs, so the first tab's own clear() empties the sibling's whether the listener
// exists or not (MEASURED under M10 in review: every localStorage assertion here
// passed with the listener DELETED). sessionStorage is per-TAB, so the precondition
// and the poll below sit on it. Moving them onto localStorage un-tests this spec.
test("logging out in one tab wipes its sibling", async ({ page, context }) => {
  await setupPhantomMock(page, { walletStandard: false });
  await loginViaPhantom(page);
  await page.goto("/account");

  // The sibling: same context, so it shares the origin, the cookie jar and the
  // channel. It also needs the mock, because it boots the same app.
  const sibling = await context.newPage();
  await setupPhantomMock(sibling, { walletStandard: false });
  await sibling.goto("/account");

  // State that only a wipe removes. Written in the SIBLING, so what we assert
  // afterwards is that the sibling reacted — not that the first tab tidied up.
  await sibling.evaluate(() => {
    localStorage.setItem("seedsNavbar", JSON.stringify({ seeds_total: 40, level: 1 }));
    localStorage.setItem("phantom_dl_pubkey", "still-logged-in");
    sessionStorage.setItem("pendingAuthStep", "buy-tokens");
  });

  // Precondition, or the assertion below can pass against a tab that never had
  // anything to lose — on the PER-TAB store, for the reason above.
  expect(await sibling.evaluate(() => sessionStorage.getItem("pendingAuthStep")))
    .toBe("buy-tokens");

  await page.locator(`a[href="/logout"]:visible`).first().click();
  await page.waitForURL(/\/signin/);

  // The sibling is NOT navigated — it must wipe in place, from the message alone.
  await expect
    .poll(() => sibling.evaluate(() => sessionStorage.getItem("pendingAuthStep")), {
      message: "the sibling tab kept its per-tab session state after a peer logged " +
               "out — the BroadcastChannel listener in session_wipe.js never fired"
    })
    .toBeNull();

  const after = await sibling.evaluate(() => ({
    local: Object.fromEntries(Object.entries(localStorage)),
    session: Object.fromEntries(Object.entries(sessionStorage))
  }));
  expect(after.local).toEqual({});
  expect(after.session).toEqual({});
});
