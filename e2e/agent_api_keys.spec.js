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
//   * BACK DOES NOT BRING THE KEY BACK. Turbo snapshots the page as the player
//     leaves it and restores that snapshot on Back with no request, so "the
//     server renders it once" says nothing about what the browser kept. Only a
//     real history traversal shows whether the raw key is in that snapshot.
//   * A REFUSAL IS SAID IN THE CARD. A frame handed a response it cannot use
//     shows "Content missing" or nothing at all, and both are things Turbo does
//     with a response, not things the server sends.
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

// A link on /account that Turbo Drive follows (same origin, not opted out).
const LEAVE_LINK = 'a[href="/"]:not([data-turbo="false"]):visible';

// Wait for a Turbo visit to FINISH, not for the URL to flip: Turbo files the
// outgoing snapshot a tick after the visit starts, and pressing Back before it
// lands sends the restoration to the network (app/javascript/turbo_snapshot_cache.js,
// e2e/cart_survives_turbo_restore.spec.js).
async function settle(page) {
  await page.evaluate(
    () =>
      new Promise((resolve) => {
        const visit =
          window.Turbo &&
          window.Turbo.session &&
          window.Turbo.session.navigator &&
          window.Turbo.session.navigator.currentVisit;
        if (!visit) return resolve();
        document.addEventListener("turbo:load", () => resolve(), { once: true });
        setTimeout(resolve, 3000);
      }),
  );
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
    // Hold the revoke so the pending state is observable rather than a race.
    // button_to sends it as a POST carrying _method=delete.
    let release;
    const held = new Promise((resolve) => (release = resolve));
    await page.route("**/account/api_keys/*", async (route) => {
      const request = route.request();
      const revoke = request.method() === "DELETE" || /_method=delete|name="_method"\s+delete/.test(request.postData() || "");
      if (revoke) await held;
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

  // The player mints a key and walks off without pressing "I've copied it".
  // Turbo files a snapshot of the page they left; Back puts that snapshot on
  // screen without asking the server. The reveal is data-turbo-temporary, so it
  // is not in the snapshot.
  test("the raw key is not shown again after leaving the page and pressing Back", async ({ page }) => {
    await openAccount(page);
    const card = page.locator(CARD);
    const key = await createKey(page, "Left on screen");
    expect(key).toMatch(KEY_FORMAT);
    await expect(card.locator("[data-api-key-created]")).toBeVisible();

    // A Turbo visit, not a document load: the marker planted by openAccount
    // has to survive it, or Back below would be an ordinary reload and prove
    // nothing about the snapshot.
    await page.locator(LEAVE_LINK).first().click();
    await page.waitForURL((u) => u.pathname !== "/account");
    await settle(page);
    await expectNoReload(page);

    // THE CONTROL: Back must be answered from Turbo's snapshot. A request for
    // /account here would mean the server re-rendered the page, and a server
    // render never had the key to show.
    const refetched = [];
    page.on("request", (req) => {
      if (req.isNavigationRequest() || new URL(req.url()).pathname === "/account") refetched.push(req.url());
    });

    await page.goBack();
    await page.waitForURL(/\/account$/);
    await settle(page);
    await expect(card).toBeVisible();
    await expectNoReload(page);
    expect(refetched, "Back was served by the network, so the snapshot was never exercised").toEqual([]);

    // The snapshot kept the card and the key's row, and dropped the reveal.
    await expect(card.locator("[data-api-key-row]")).toHaveCount(1);
    await expect(card.locator("[data-api-key-row]")).toContainText("Left on screen");
    await expect(card.locator("[data-api-key-created]")).toHaveCount(0);
    await expect(card.locator("[data-api-key-secret]")).toHaveCount(0);
    expect(await page.content()).not.toContain(key);

    // The reveal took its only exit ("I've copied it") with it, so the restored
    // card offers its own way on: one click, in place, to the open form.
    const after = card.locator("[data-api-key-add-after-reveal]");
    await expect(after).toBeVisible();
    await after.getByRole("link", { name: "Add another API key" }).click();
    await expect(card.getByLabel("Name")).toBeVisible();
    await expect(card.locator("[data-api-key-add-after-reveal]")).toHaveCount(0);
    await expectNoReload(page);
    await expect(page).toHaveURL(/\/account$/);
    const second = await createKey(page, "After Back");
    expect(second).toMatch(KEY_FORMAT);
    // And while a reveal IS on screen, that link stays out of the way.
    await expect(card.locator("[data-api-key-add-after-reveal]")).toBeHidden();
  });

  // The mint throttle is rack-attack's, and rack-attack is off in the e2e
  // server (config/initializers/rack_attack.rb), so the 429 is played back here
  // with the body the real responder sends; test/integration/api_rate_limit_test.rb
  // pins that the real one is a JSON 429 with no card in it. What this spec
  // owns is the browser half: Turbo gets a response it cannot render, and the
  // form says why instead of sitting there silent.
  test("a throttled mint says so in the card", async ({ page }) => {
    await openAccount(page);
    const card = page.locator(CARD);
    const throttled = card.locator("[data-api-key-throttled]");
    await expect(throttled).toBeHidden();

    let throttle = true;
    await page.route("**/account/api_keys", async (route) => {
      if (route.request().method() !== "POST" || !throttle) return route.continue();
      await route.fulfill({
        status: 429,
        contentType: "application/json",
        headers: { "Retry-After": "3600", "X-RateLimit-Tier": "general" },
        body: JSON.stringify({ error: "Too many requests. Try again later.", tier: "general", retry_after: 3600 }),
      });
    });

    await card.getByLabel("Name").fill("One too many");
    await card.getByRole("button", { name: "Create key" }).click();

    await expect(throttled).toBeVisible();
    await expect(throttled).toContainText("too many keys");
    // The card is intact and usable: no key, no spinner left behind, what was typed kept.
    await expect(card.locator("[data-api-key-secret]")).toHaveCount(0);
    await expect(card.getByRole("button", { name: "Create key" })).toBeEnabled();
    await expect(card.getByLabel("Name")).toHaveValue("One too many");
    await expect(card).not.toContainText("Content missing");
    await expectNoReload(page);

    // A refusal about the name, then a throttle: one message at a time. The
    // 422 is the server's own; the 429 after it must not sit beside it.
    throttle = false;
    await card.getByLabel("Name").fill("   ");
    await card.getByRole("button", { name: "Create key" }).click();
    await expect(card.locator("[data-api-key-error]")).toHaveText("Name can't be blank");
    throttle = true;
    await card.getByLabel("Name").fill("One too many");
    await card.getByRole("button", { name: "Create key" }).click();
    await expect(card.locator("[data-api-key-throttled]")).toBeVisible();
    await expect(card.locator("[data-api-key-error]")).toBeHidden();

    // Once the throttle lifts, the same form works and the message goes.
    throttle = false;
    const key = await createKey(page, "One too many");
    expect(key).toMatch(KEY_FORMAT);
    await expect(card.locator("[data-api-key-throttled]")).toHaveCount(0);
    await expectNoReload(page);
  });

  // A real 404 from the server: the row's form is pointed at a key id that does
  // not exist, which is what a row left on screen after its key is gone would do.
  test("a revoke the server refuses says so in the card, not Content missing", async ({ page }) => {
    await openAccount(page);
    const card = page.locator(CARD);
    await createKey(page, "Stays");
    await card.getByRole("link", { name: "I've copied it" }).click();
    // The row is already listed under the reveal, so wait for the reveal to go:
    // the frame swap that removes it also replaces the row this is about to edit.
    await expect(card.locator("[data-api-key-created]")).toHaveCount(0);
    await expect(card.locator("[data-api-key-add]")).toBeVisible();
    const row = card.locator("[data-api-key-row]");
    await expect(row).toHaveCount(1);

    await row.locator("form").evaluate((form) => {
      form.action = form.action.replace(/\/\d+$/, "/0");
    });
    const statuses = [];
    page.on("response", (res) => {
      // button_to sends the DELETE as a POST carrying _method.
      if (new URL(res.url()).pathname === "/account/api_keys/0") statuses.push(res.status());
    });
    page.on("dialog", (dialog) => dialog.accept());
    await row.getByRole("button", { name: "Revoke" }).click();

    const error = card.locator("[data-api-key-card-error]");
    await expect(error).toBeVisible();
    await expect(error).toContainText("no longer on your account");
    expect(statuses, "the refusal must be the server's own 404").toEqual([404]);
    await expect(card).not.toContainText("Content missing");
    // Nothing was revoked, the row is back with no spinner, and the page stood still.
    await expect(row).toHaveCount(1);
    await expect(row).toContainText("Stays");
    await expect(row.locator(".cta-spinner")).toBeHidden();
    await expect(row.getByRole("button", { name: "Revoke" })).toBeEnabled();
    await expectNoReload(page);
    await expect(page).toHaveURL(/\/account$/);
  });
});
