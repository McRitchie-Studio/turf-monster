const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] The agent API keys card on /account: create a key, copy it from the
// one render that shows it, use it as a bearer credential, add another, revoke.
//
// WHAT ONLY A BROWSER CAN SHOW HERE.
//
//   * THE CARD UPDATES IN PLACE. It is a Turbo Frame, and every server response
//     carries that frame — which the integration tier proves. Whether Turbo
//     then swaps the card and leaves the page alone is a runtime fact. Each
//     spec plants a marker on `window` and asserts it survives: a full page
//     load, however it came about, wipes it.
//   * The key is shown ONCE. Only a browser proves a person can get it OUT of
//     that render (the engine copy button really writes the clipboard) and
//     that dismissing it leaves no way back.
//   * The spinner and the confirm are wired to Turbo's submit events and a data
//     attribute. Both are inert strings to every server-side test.
//   * The age gate is passed in a MODAL that knows nothing about this card. The
//     card finds out from a window event and re-fetches itself; a lower tier can
//     see the listener is written, never that it fires.
//
// The e2e server runs with ENABLE_AGE_GATE on and seeds its users age-verified,
// with geo-blocking off. The refusals are covered where they are decided:
// test/controllers/api_keys_controller_test.rb.
test.beforeEach(async ({ request }) => await reseed(request));

const KEY_FORMAT = /^tmk_[A-Za-z0-9]{40}$/;
const CARD = "turbo-frame#api_keys_card";

// A full page load discards `window`, so a marker that is still there proves
// everything since it was planted happened in place.
async function plantReloadMarker(page) {
  await page.evaluate(() => {
    window.__apiKeysNoReload = true;
  });
}

async function expectNoReload(page) {
  expect(
    await page.evaluate(() => window.__apiKeysNoReload === true),
    "the page reloaded; the card was meant to update in place",
  ).toBe(true);
}

async function openAccount(page) {
  await loginAdmin(page);
  await page.goto("/account");
  await expect(page.locator(CARD)).toBeVisible();
  await plantReloadMarker(page);
}

async function createKey(page, name) {
  const card = page.locator(CARD);
  await card.getByLabel("Name").fill(name);
  await card.getByRole("button", { name: "Create key" }).click();
  const secret = card.locator("[data-api-key-secret]");
  await expect(secret).toBeVisible();
  return (await secret.locator("[data-api-key-value]").innerText()).trim();
}

// The seeded admin starts every spec verified, whatever a failed run left behind.
test.afterEach(async ({ page }) => {
  await page.request.post("/test/set_age_verified", { data: { verified: true } }).catch(() => {});
});

test.describe("Agent API keys", () => {
  test("create a key, copy it once, use it, then revoke it, all without a page load @smoke", async ({
    page,
    context,
    request,
  }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await openAccount(page);
    const card = page.locator(CARD);

    // No keys yet: the form is the card, with no "add another" in front of it.
    await expect(card.locator("[data-api-key-row]")).toHaveCount(0);
    await expect(card.locator("[data-api-key-add]")).toHaveCount(0);
    await expect(card.getByLabel("Name")).toBeVisible();

    // --- create ---------------------------------------------------------------
    const key = await createKey(page, "Playwright agent");
    expect(key).toMatch(KEY_FORMAT);
    await expectNoReload(page);
    await expect(page).toHaveURL(/\/account$/);

    // --- copy -----------------------------------------------------------------
    const secret = card.locator("[data-api-key-secret]");
    await secret.getByRole("button", { name: "Copy" }).click();
    await expect(secret.getByText("Copied")).toBeVisible();
    expect(await page.evaluate(() => navigator.clipboard.readText())).toBe(key);

    // --- use ------------------------------------------------------------------
    // The `request` fixture is its own cookie jar: it carries no session, so a
    // 200 here is the key authenticating by itself.
    const me = await request.get("/api/v1/me", { headers: { Authorization: `Bearer ${key}` } });
    expect(me.status()).toBe(200);
    const body = await me.json();
    expect(body.api_key.name).toBe("Playwright agent");
    expect(body.api_key.prefix).toBe(key.slice(0, 10));
    expect(body.api_key.eligibility.geo.result).toBe("allowed");
    expect(body.api_key.eligibility.age_gate).toBe("passed");

    const anonymous = await request.get("/api/v1/me");
    expect(anonymous.status()).toBe(401);
    expect((await anonymous.json()).error.code).toBe("missing_api_key");

    // --- shown once -----------------------------------------------------------
    await card.getByRole("link", { name: "I've copied it" }).click();
    await expect(card.locator("[data-api-key-created]")).toHaveCount(0);
    const row = card.locator("[data-api-key-row]");
    await expect(row).toHaveCount(1);
    await expect(row).toContainText(`${key.slice(0, 10)}…`);
    await expect(row).toContainText("Playwright agent");
    expect(await page.content()).not.toContain(key);
    await expectNoReload(page);

    // --- revoke ---------------------------------------------------------------
    // Hold the DELETE so the pending state is observable rather than a race.
    let release;
    const held = new Promise((resolve) => (release = resolve));
    await page.route("**/account/api_keys/*", async (route) => {
      if (route.request().method() === "DELETE") await held;
      await route.continue();
    });

    let asked = null;
    page.on("dialog", async (dialog) => {
      asked = dialog.message();
      await dialog.accept();
    });
    await row.getByRole("button", { name: "Revoke" }).click();

    await expect(row.locator(".cta-spinner")).toBeVisible();
    await expect(row).toContainText("Revoking");
    expect(asked, "Revoke must raise a confirm dialog").toMatch(/stops working immediately/);

    release();
    await expect(card.locator("[data-api-key-row]")).toHaveCount(0);
    // Back to the empty card, form and all, with the page untouched.
    await expect(card.getByLabel("Name")).toBeVisible();
    await expectNoReload(page);
    await expect(page).toHaveURL(/\/account$/);

    const revoked = await request.get("/api/v1/me", { headers: { Authorization: `Bearer ${key}` } });
    expect(revoked.status()).toBe(401);
    expect((await revoked.json()).error.code).toBe("revoked_api_key");
  });

  test("declining the revoke confirm keeps the key and leaves no spinner", async ({ page }) => {
    await openAccount(page);
    const card = page.locator(CARD);
    await createKey(page, "Keeper");
    await card.getByRole("link", { name: "I've copied it" }).click();
    const row = card.locator("[data-api-key-row]");
    await expect(row).toHaveCount(1);

    const deletes = [];
    page.on("request", (req) => {
      if (req.method() === "DELETE") deletes.push(req.url());
    });
    let asked = false;
    page.on("dialog", async (dialog) => {
      asked = true;
      await dialog.dismiss();
    });
    await row.getByRole("button", { name: "Revoke" }).click();
    await page.waitForTimeout(750);

    expect(asked, "Revoke must raise a confirm dialog").toBe(true);
    expect(deletes, "dismissing the confirm must cancel the request").toHaveLength(0);
    await expect(row).toHaveCount(1);
    await expect(row.locator(".cta-spinner")).toBeHidden();
    await expect(row.getByRole("button", { name: "Revoke" })).toBeEnabled();
  });

  test("with a key already, the form waits behind Add another API key", async ({ page }) => {
    await openAccount(page);
    const card = page.locator(CARD);
    await createKey(page, "First");
    await card.getByRole("link", { name: "I've copied it" }).click();
    await expect(card.locator("[data-api-key-row]")).toHaveCount(1);

    // Rendered but closed: the link is what a player sees.
    const add = card.locator("[data-api-key-add]");
    await expect(add).toBeVisible();
    await expect(add).toHaveText("Add another API key");
    await expect(card.getByLabel("Name")).toBeHidden();
    await expect(card.getByRole("button", { name: "Create key" })).toBeHidden();

    await add.click();
    await expect(card.getByLabel("Name")).toBeVisible();
    await expect(card.getByLabel("Name")).toBeFocused();
    await expect(add).toBeHidden();

    const second = await createKey(page, "Second");
    expect(second).toMatch(KEY_FORMAT);
    await card.getByRole("link", { name: "I've copied it" }).click();
    await expect(card.locator("[data-api-key-row]")).toHaveCount(2);
    // And it is closed again for the next one.
    await expect(card.locator("[data-api-key-add]")).toBeVisible();
    await expect(card.getByLabel("Name")).toBeHidden();
    await expectNoReload(page);
  });

  test("a name is required: the server refuses a blank one inline and mints nothing", async ({ page }) => {
    await openAccount(page);
    const card = page.locator(CARD);
    const name = card.getByLabel("Name");

    // The browser's own check comes first...
    await card.getByRole("button", { name: "Create key" }).click();
    expect(await name.evaluate((el) => el.validity.valueMissing)).toBe(true);
    await expect(card.locator("[data-api-key-secret]")).toHaveCount(0);

    // ...and is not the boundary. Whitespace satisfies `required`; the server
    // still refuses it, in the card, without a page load.
    await name.fill("   ");
    await card.getByRole("button", { name: "Create key" }).click();

    const error = card.locator("[data-api-key-error]");
    await expect(error).toHaveText("Name can't be blank");
    await expect(card.getByLabel("Name")).toBeVisible();
    await expect(card.locator("[data-api-key-secret]")).toHaveCount(0);
    await expect(card.locator("[data-api-key-row]")).toHaveCount(0);
    await expectNoReload(page);

    // The refused form still works.
    const key = await createKey(page, "Named");
    expect(key).toMatch(KEY_FORMAT);
  });

  test("passing the age gate reveals the create form without a reload", async ({ page }) => {
    await loginAdmin(page);
    const cleared = await page.request.post("/test/set_age_verified", { data: { verified: false } });
    expect(cleared.ok(), `set_age_verified failed: ${cleared.status()}`).toBeTruthy();

    await page.goto("/account");
    const card = page.locator(CARD);
    await expect(card.locator('[data-api-key-blocked="age"]')).toBeVisible();
    await expect(card.getByLabel("Name")).toHaveCount(0);
    await plantReloadMarker(page);

    await card.getByRole("button", { name: "Verify age" }).click();
    await expect(page.locator('h3:text-is("Your birthday")')).toBeVisible();
    await page.selectOption('select[x-model="month"]', "1");
    await page.selectOption('select[x-model="day"]', "1");
    await page.selectOption('select[x-model="year"]', String(new Date().getFullYear() - 30));
    await page.locator('button:has-text("Confirm & Continue")').click();

    // The modal closes and the card, told only by a window event, re-fetches
    // itself: the blocker is gone and the form is there.
    await expect(page.locator('h3:text-is("Your birthday")')).toBeHidden();
    await expect(card.getByLabel("Name")).toBeVisible();
    await expect(card.locator("[data-api-key-blocked]")).toHaveCount(0);
    await expectNoReload(page);
    await expect(page).toHaveURL(/\/account$/);

    // And the form it revealed is live.
    const key = await createKey(page, "After the gate");
    expect(key).toMatch(KEY_FORMAT);
    await expectNoReload(page);
  });
});
