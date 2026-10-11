const { test, expect } = require("@playwright/test");
const { login, grantManagedWallet, reseed } = require("./helpers");

// [e2e] The account and wallet controls that left Alpine for static Stimulus
// controllers: the referral card, the newsletter card, the email change
// notice, the API keys card's add-another link, the cash-out card and the
// wallet balance.
//
// THE EARLY PRESS. These controllers are static (imported by turf_stimulus.js
// and preloaded on every page), so each spec presses AT ONCE: straight after
// goto, and straight after a Turbo visit renders the page, with no wait on the
// controller. A press that is lost fails the assertion that follows it.
//
// Every controller and logic module answers 300 ms late, so the specs bite: a
// preloaded module holds the page's load until it has run, while a lazy one is
// fetched only after the page has loaded, and a press in that window is lost.
//
// The API keys card's busy, throttle, reveal and age-gate behaviour is driven
// end to end by agent_api_keys.spec.js; the desktop-only notice by
// admin_desktop_only.spec.js.
test.beforeEach(async ({ page, request }) => {
  await reseed(request);
  await page.route(/\/assets\/(?:controllers|turf)\/[\w-]+\.js/, async (route) => {
    await new Promise((resolve) => setTimeout(resolve, 300));
    await route.continue();
  });
});

// A fresh player per spec, so no state carries between them.
async function signIn(page, label) {
  await login(page, `entry-stimulus-${label}-${Date.now()}@example.test`);
}

// A Turbo visit, resolving once the new page's `selector` has rendered (not
// merely the old one's). It stays in this document unless it enters or leaves
// a signing page (SigningCsp): those are always full loads, so the press after
// it is a press straight after a fresh load.
const onSigningPage = (page) => page.evaluate(() => !!document.querySelector('meta[name="signing-csp"]'));

async function turboVisit(page, path, selector) {
  const leaving = await onSigningPage(page);
  await page.evaluate((s) => {
    window.__sameDocument = true;
    document.querySelectorAll(s).forEach((el) => (el.__beforeVisit = true));
  }, selector);
  await page.evaluate((p) => window.Turbo.visit(p), path);
  await page.waitForFunction((s) => {
    const el = document.querySelector(s);
    return !!el && !el.__beforeVisit;
  }, selector);
  const crossed = leaving || (await onSigningPage(page));
  expect(await page.evaluate(() => window.__sameDocument)).toBe(crossed ? undefined : true);
  // A full load is pressed after its load event, as page.goto() would be.
  if (crossed) await page.waitForLoadState("load");
}

// Wait for a Turbo visit to finish filing its snapshot before Back.
async function settled(page) {
  await page.waitForFunction(() => !(window.Turbo && window.Turbo.session.navigator.currentVisit && window.Turbo.session.navigator.currentVisit.state === "started"));
}

test.describe("referral card", () => {
  const info = (page) => page.getByRole("button", { name: "How invites work" });
  const popover = (page) => page.locator('[data-referral-share-target="popover"]');
  const copy = (page) => page.locator('[data-referral-share-target="button"]');

  test("the info toggle and Copy Link pressed straight after load", async ({ page, context }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await signIn(page, "referral");
    await page.goto("/account");

    await info(page).click();
    await expect(popover(page)).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(popover(page)).toBeHidden();

    await info(page).click();
    await expect(popover(page)).toBeVisible();
    await popover(page).getByText("How it works").click();
    await expect(popover(page)).toBeVisible();
    await page.getByRole("heading", { name: "Account Settings" }).click();
    await expect(popover(page)).toBeHidden();

    await info(page).click();
    await expect(popover(page)).toBeVisible();
    await popover(page).getByRole("button", { name: "Close" }).click();
    await expect(popover(page)).toBeHidden();

    const url = await page.locator('[data-controller="referral-share"]').getAttribute("data-referral-share-url-value");
    await copy(page).click();
    await expect(copy(page).locator('[data-referral-share-target="copiedLabel"]')).toBeVisible();
    await expect(copy(page).locator('[data-referral-share-target="copyLabel"]')).toBeHidden();
    await expect(copy(page)).toHaveClass(/btn-secondary/);
    expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(url);
    await expect(copy(page).locator('[data-referral-share-target="copyLabel"]')).toBeVisible({ timeout: 3000 });
    await expect(copy(page)).toHaveClass(/btn-primary/);
  });

  test("the keyboard opens the info popover", async ({ page }) => {
    await signIn(page, "referral-keys");
    await page.goto("/account");
    await info(page).focus();
    await page.keyboard.press("Enter");
    await expect(popover(page)).toBeVisible();
    await page.keyboard.press("Escape");
    await expect(popover(page)).toBeHidden();
  });

  test("pressed straight after a Turbo visit, and Back starts closed", async ({ page }) => {
    await signIn(page, "referral-turbo");
    await page.goto("/help");
    await turboVisit(page, "/account", '[data-controller="referral-share"]');
    await info(page).click();
    await expect(popover(page)).toBeVisible();

    await turboVisit(page, "/help", 'a[href="/help/how-to-play"]');
    await settled(page);
    await page.goBack();
    await expect(page).toHaveURL(/\/account$/);
    await expect(info(page)).toBeVisible();
    await expect(popover(page)).toBeHidden();
  });
});

test.describe("newsletter card", () => {
  const subscribed = (page) => page.locator('[data-newsletter-state-target="subscribed"]');
  const unsubscribed = (page) => page.locator('[data-newsletter-state-target="unsubscribed"]');
  const announce = (page, value) =>
    page.evaluate((v) => window.dispatchEvent(new CustomEvent("newsletter-state-changed", { detail: { subscribed: v } })), value);

  test("follows the modals' event straight after load, and after a Turbo visit", async ({ page }) => {
    await signIn(page, "newsletter");
    await page.goto("/account");
    await expect(unsubscribed(page)).toBeVisible();
    await expect(subscribed(page)).toBeHidden();

    await announce(page, true);
    await expect(subscribed(page)).toBeVisible();
    await expect(unsubscribed(page)).toBeHidden();
    await announce(page, false);
    await expect(unsubscribed(page)).toBeVisible();

    await page.goto("/help");
    await turboVisit(page, "/account", '[data-controller="newsletter-state"]');
    await announce(page, true);
    await expect(subscribed(page)).toBeVisible();
  });

  test("Subscribe still opens the app's modal", async ({ page }) => {
    await signIn(page, "newsletter-modal");
    await page.goto("/account");
    await unsubscribed(page).getByRole("button", { name: "Subscribe", exact: true }).click();
    await expect(page.locator('[role="dialog"]')).toBeVisible();
  });
});

test.describe("email change notice", () => {
  const field = (page) => page.locator('input[data-email-change-notice-target="field"]');
  const notice = (page) => page.locator('[data-email-change-notice-target="notice"]');

  test("typing straight after load says a link goes to the current address", async ({ page }) => {
    await signIn(page, "email");
    await page.goto("/account");
    const current = await field(page).inputValue();
    expect(current).toMatch(/@example\.test$/);

    await field(page).fill("someone-new@example.test");
    await expect(notice(page)).toBeVisible();
    await field(page).fill(current.toUpperCase());
    await expect(notice(page)).toBeHidden();
  });

  test("typing straight after a Turbo visit, and Back starts hidden", async ({ page }) => {
    await signIn(page, "email-turbo");
    await page.goto("/help");
    await turboVisit(page, "/account", '[data-controller="email-change-notice"]');
    await field(page).fill("someone-new@example.test");
    await expect(notice(page)).toBeVisible();

    await turboVisit(page, "/help", 'a[href="/help/how-to-play"]');
    await settled(page);
    // /account is a signing page (SigningCsp), so Back is a fresh load, not a
    // Turbo restoration. The browser puts back what was typed, and the notice
    // reads the field as it connects, so the two still agree.
    await page.goBack();
    await expect(page).toHaveURL(/\/account$/);
    await expect(field(page)).toHaveValue("someone-new@example.test");
    await expect(notice(page)).toBeVisible();
  });
});

test.describe("API keys add-another link", () => {
  const CARD = "turbo-frame#api_keys_card";

  // A fresh player is not yet age verified, and the card offers no form until
  // they are.
  async function verified(page, label) {
    await signIn(page, label);
    const verify = await page.request.post("/test/set_age_verified", { data: { verified: true } });
    expect(verify.ok()).toBeTruthy();
  }

  async function withOneKey(page, label) {
    await verified(page, label);
    await page.goto("/account");
    const card = page.locator(CARD);
    await card.getByLabel("Name").fill("First");
    await card.getByRole("button", { name: "Create key" }).click();
    await expect(card.locator("[data-api-key-secret]")).toBeVisible();
    await card.getByRole("link", { name: "I've copied it" }).click();
    await expect(card.locator("[data-api-key-row]")).toHaveCount(1);
  }

  test("the age gate's event, straight after load, re-fetches the card with its form", async ({ page }) => {
    await signIn(page, "keys-age");
    await page.goto("/account");
    const card = page.locator(CARD);
    await expect(card.locator('[data-api-key-blocked="age"]')).toBeVisible();
    const verify = await page.request.post("/test/set_age_verified", { data: { verified: true } });
    expect(verify.ok()).toBeTruthy();
    await page.evaluate(() => window.dispatchEvent(new CustomEvent("age-verified")));
    await expect(card.getByLabel("Name")).toBeVisible();
    await expect(card.locator('[data-api-key-blocked="age"]')).toHaveCount(0);
  });

  test("pressed straight after load opens the form and focuses the name", async ({ page }) => {
    await withOneKey(page, "keys");
    await page.goto("/account");
    const card = page.locator(CARD);
    await card.getByRole("button", { name: "Add another API key" }).click();
    await expect(card.getByLabel("Name")).toBeVisible();
    await expect(card.getByLabel("Name")).toBeFocused();
    await expect(card.getByRole("button", { name: "Add another API key" })).toBeHidden();
  });

  test("pressed straight after a Turbo visit, and Back starts closed", async ({ page }) => {
    await withOneKey(page, "keys-turbo");
    await page.goto("/help");
    await turboVisit(page, "/account", `${CARD} [data-controller="reveal"]`);
    const card = page.locator(CARD);
    await card.getByRole("button", { name: "Add another API key" }).click();
    await expect(card.getByLabel("Name")).toBeVisible();

    await turboVisit(page, "/help", 'a[href="/help/how-to-play"]');
    await settled(page);
    await page.goBack();
    await expect(page).toHaveURL(/\/account$/);
    await expect(card.getByRole("button", { name: "Add another API key" })).toBeVisible();
    await expect(card.getByLabel("Name")).toBeHidden();
  });
});

test.describe("cash-out card", () => {
  const card = (page) => page.locator("#cash-out");
  const toggle = (page) => card(page).locator('[data-withdraw-card-target="toggle"]');
  const panel = (page) => card(page).locator('[data-withdraw-card-target="panel"]');
  const submit = (page) => card(page).getByRole("button", { name: "Submit withdrawal" });

  async function managedPlayer(page, label) {
    await signIn(page, label);
    await grantManagedWallet(page);
  }

  test("Withdraw pressed straight after load opens the form; the submit waits for both fields", async ({ page }) => {
    await managedPlayer(page, "cashout");
    await page.goto("/wallet");
    await expect(page.locator('[data-usdc-balance-target="amount"]')).toHaveText(/^\d+\.\d{2}$/);

    await toggle(page).click();
    await expect(panel(page)).toBeVisible();
    await expect(toggle(page)).toHaveText("Cancel");
    await expect(submit(page)).toBeDisabled();

    await card(page).getByLabel("Amount (USD)").fill("12");
    await expect(submit(page)).toBeDisabled();
    await card(page).getByLabel("Where should we send it?").fill("PayPal @fan");
    await expect(submit(page)).toBeEnabled();
    await card(page).getByLabel("Amount (USD)").fill("");
    await expect(submit(page)).toBeDisabled();

    await toggle(page).click();
    await expect(panel(page)).toBeHidden();
    await expect(toggle(page)).toHaveText("Withdraw");
  });

  test("the page opens the form when reached at #cash-out", async ({ page }) => {
    await managedPlayer(page, "cashout-hash");
    await page.goto("/wallet#cash-out");
    await expect(panel(page)).toBeVisible();
    await expect(toggle(page)).toHaveText("Cancel");
  });

  test("Withdraw pressed straight after a Turbo visit, and Back starts closed", async ({ page }) => {
    await managedPlayer(page, "cashout-turbo");
    await page.goto("/help");
    await turboVisit(page, "/wallet", '[data-controller="withdraw-card"]');
    await toggle(page).click();
    await expect(panel(page)).toBeVisible();
    await card(page).getByLabel("Amount (USD)").fill("12");

    await turboVisit(page, "/help", 'a[href="/help/how-to-play"]');
    await settled(page);
    // /wallet is a signing page (SigningCsp), so Back is a fresh load: the
    // card starts closed, and the browser keeps the amount that was typed.
    await page.goBack();
    await expect(page).toHaveURL(/\/wallet$/);
    await expect(toggle(page)).toHaveText("Withdraw");
    await expect(panel(page)).toBeHidden();
    await expect(card(page).getByLabel("Amount (USD)")).toHaveValue("12");
  });
});
