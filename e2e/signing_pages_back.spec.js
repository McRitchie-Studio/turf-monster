const { test, expect } = require("@playwright/test");
const { login, loginAdmin, grantManagedWallet, reseed } = require("./helpers");

// [e2e] Three things a signing page (SigningCsp) lost when it became its own
// document, task signing-pages-back-regressions. Every signing page is entered
// and left by a full load (turbo-visit-control reload, signing_document), so
// Back to one is a fresh load, never a Turbo restore. Each spec here walks the
// journey a player or an operator walks and reads what the page shows.
//
//   1. A form posted from a signing page whose redirect lands OFF the signing
//      pages: Turbo fetches the redirect target inside the form submission,
//      signing_document then leaves by a full load, and the flash the save set
//      was spent on the body nobody saw.
//   2. Back after a paid entry: the cart rides sessionStorage across Back, so
//      the stored cart has to say the picks became an entry.
//   3. Back to the cash-out form: the browser puts the typed fields back after
//      the controller has read them, so the submit has to look again.
test.beforeEach(async ({ request }) => await reseed(request));

const CONTEST = "/contests/world-cup-2026";
const SLOTS = "#entry-sidebar div.overflow-y-auto > div";
const json = (status, body) => ({ status, contentType: "application/json", body: JSON.stringify(body) });

test("saving the contest edit page shows Contest updated.", async ({ page }) => {
  await loginAdmin(page);
  await page.goto(`${CONTEST}/edit`);
  await expect(page.locator('meta[name="signing-csp"]')).toHaveCount(1);

  await page.getByRole("button", { name: "Save Changes" }).click();
  await page.waitForURL((u) => u.pathname === "/contests");
  await page.waitForLoadState("load");

  await expect(page.locator("body")).toContainText("Contest updated.");
});

// The board only POSTs /enter for a wallet it believes can fund the entry, so
// the session holds one free entry (as e2e/board_hold_enters_once.spec.js
// does), the funding pre-check says a token pays, and /enter answers as a
// confirmed entry does. The payment itself is not what this spec is about:
// money is already safe (a second entry is refused); what Back shows is.
async function holdOneToken(page) {
  await page.waitForFunction(() => typeof window.refreshSession === "function");
  await page.route("**/account/session_refresh", (route) =>
    route.fulfill(json(200, { usdc: "0.0", usdt: "0.0", tokens: "1" }))
  );
  await expect
    .poll(
      async () => {
        await page.evaluate(() => window.refreshSession().catch(() => null));
        return page.evaluate(() => Alpine.store("session").tokensAvailable);
      },
      { timeout: 20000, intervals: [500, 1000, 1000, 1500, 2000] }
    )
    .toBe(1);
}

async function pickSix(page) {
  const cards = page.locator('[x-data*="selectionBoard"] button[role="checkbox"]:not([disabled])');
  for (let i = 0; i < 6; i++) {
    const blurOverlay = page.locator("div.fixed.inset-0.z-20.cursor-pointer");
    if (await blurOverlay.isVisible({ timeout: 300 }).catch(() => false)) await blurOverlay.click();
    await cards.nth(i).click();
    await expect(page.locator("body")).toContainText(`${i + 1} / 6`);
  }
}

const holdEvent = (page, name) =>
  page.evaluate((eventName) => {
    const button = document.querySelector('.hold-btn[data-hold-id="desktop"]');
    button.dispatchEvent(new CustomEvent(`hold-button:${eventName}`, { bubbles: true, cancelable: true, detail: { id: "desktop" } }));
  }, name);

test("Back after a paid entry shows an empty cart", async ({ page }) => {
  await loginAdmin(page);
  await page.goto(CONTEST);
  await page.waitForFunction(() => !!document.querySelector(".hold-btn") && !!window.Alpine);
  // Start from an empty server cart, and a page rendered with it.
  await page.evaluate(async (contest) => {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
    await fetch(`${contest}/clear_picks`, { method: "POST", headers: { "X-CSRF-Token": csrfToken, Accept: "application/json" } });
  }, CONTEST);
  await page.reload();
  await page.waitForFunction(() => !!document.querySelector(".hold-btn") && !!window.Alpine);
  await holdOneToken(page);
  await pickSix(page);

  const lobby = `${CONTEST}/contest`;
  await page.route("**/contests/*/check_funding", (route) => route.fulfill(json(200, { fundable: true, reason: null, method: "token" })));
  await page.route("**/contests/*/enter", (route) => route.fulfill(json(200, { success: true, redirect: lobby })));

  await page.evaluate(() => (Alpine.store("session").mode = "web2"));
  await holdEvent(page, "start");
  await holdEvent(page, "success");
  await page.waitForURL((u) => u.pathname === lobby);
  await page.waitForLoadState("load");

  await page.goBack();
  await page.waitForURL((u) => u.pathname === CONTEST);
  await page.waitForFunction(() => {
    const el = document.querySelector('[x-data*="selectionBoard"]');
    return !!el && !!window.Alpine && !!el._x_dataStack;
  });

  // The control that this Back really read the stored cart: a back/forward load.
  expect(await page.evaluate(() => performance.getEntriesByType("navigation")[0].type)).toBe("back_forward");
  await expect(page.locator("body")).toContainText("0 / 6");
  await expect(page.locator("body")).not.toContainText("6 / 6");
});

test.describe("cash-out card", () => {
  const card = (page) => page.locator("#cash-out");
  const toggle = (page) => card(page).locator('[data-withdraw-card-target="toggle"]');
  const submit = (page) => card(page).getByRole("button", { name: "Submit withdrawal" });

  test("Cash-out submit enables when Back restores the fields", async ({ page }) => {
    await login(page, `signing-back-cashout-${Date.now()}@example.test`);
    await grantManagedWallet(page);
    await page.goto("/wallet");
    await toggle(page).click();
    await card(page).getByLabel("Amount (USD)").fill("12");
    await card(page).getByLabel("Where should we send it?").fill("PayPal @fan");
    await expect(submit(page)).toBeEnabled();

    // Leave by a link, as a player would: /wallet is a signing page, so this
    // is a full load, and so is Back.
    await page.evaluate(() => window.Turbo.visit("/help"));
    await page.waitForURL((u) => u.pathname === "/help");
    await page.waitForLoadState("load");
    await page.goBack();
    await page.waitForURL((u) => u.pathname === "/wallet");
    await page.waitForLoadState("load");

    // The browser put both fields back; the submit has to agree with them.
    await expect(card(page).getByLabel("Amount (USD)")).toHaveValue("12");
    await expect(card(page).getByLabel("Where should we send it?")).toHaveValue("PayPal @fan");
    await toggle(page).click();
    await expect(submit(page)).toBeEnabled();
  });
});
