const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] An agent API key, end to end: create it on /account, copy it from the
// one page that shows it, use it as a bearer credential, revoke it.
//
// WHAT ONLY A BROWSER CAN SHOW HERE.
//
//   * The key is shown ONCE. The integration tier proves the create response
//     contains it; only a browser proves a person can get it OUT of that page
//     (the engine copy button really writes the clipboard) and that navigating
//     away leaves no way back to it.
//   * The create form submits as a full page load. It is marked turbo: false
//     because Turbo will not render a non-redirect success for a form
//     submission; if that attribute is lost the click does nothing visible, and
//     no server-side test can see that.
//   * Revoke sits behind turbo_confirm, a data attribute whose wiring is a
//     runtime fact (see admin_free_entry_burn_confirm.spec.js).
//
// The e2e server runs with ENABLE_AGE_GATE on and seeds its users as
// age-verified, with geo-blocking off — so the signed-in admin is eligible, and
// this spec walks the path an eligible player walks. The refusals are covered
// where they are decided: test/controllers/api_keys_controller_test.rb.
test.beforeEach(async ({ request }) => await reseed(request));

const KEY_FORMAT = /^tmk_[A-Za-z0-9]{40}$/;

test.describe("Agent API keys", () => {
  test("create a key on the account page, copy it once, use it, then revoke it @smoke", async ({
    page,
    context,
    request,
  }) => {
    await context.grantPermissions(["clipboard-read", "clipboard-write"]);
    await loginAdmin(page);
    await page.goto("/account");

    const card = page.locator("[data-api-keys]");
    await expect(card).toBeVisible();
    await expect(card.locator("[data-api-key-row]")).toHaveCount(0);

    // --- create ---------------------------------------------------------------
    await card.getByPlaceholder("e.g. Claude").fill("Playwright agent");
    await card.getByRole("button", { name: "Create key" }).click();

    await expect(page.getByRole("heading", { name: "Your new API key" })).toBeVisible();
    const secret = page.locator("[data-api-key-secret]");
    const key = (await secret.locator("code").innerText()).trim();
    expect(key).toMatch(KEY_FORMAT);

    // --- copy -----------------------------------------------------------------
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
    await page.getByRole("link", { name: "I've copied it" }).click();
    await expect(page).toHaveURL(/\/account$/);

    const row = page.locator("[data-api-keys] [data-api-key-row]");
    await expect(row).toHaveCount(1);
    await expect(row).toContainText(`${key.slice(0, 10)}…`);
    await expect(row).toContainText("Playwright agent");
    expect(await page.content()).not.toContain(key);

    // --- revoke ---------------------------------------------------------------
    let asked = null;
    page.on("dialog", async (dialog) => {
      asked = dialog.message();
      await dialog.accept();
    });
    await row.getByRole("button", { name: "Revoke" }).click();

    await expect(page.locator("[data-api-keys] [data-api-key-row]")).toHaveCount(0);
    expect(asked, "Revoke must raise a confirm dialog").toMatch(/stops working immediately/);

    const revoked = await request.get("/api/v1/me", { headers: { Authorization: `Bearer ${key}` } });
    expect(revoked.status()).toBe(401);
    expect((await revoked.json()).error.code).toBe("revoked_api_key");
  });
});
