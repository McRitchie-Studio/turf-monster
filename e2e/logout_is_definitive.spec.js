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
