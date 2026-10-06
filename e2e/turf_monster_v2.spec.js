const { test, expect } = require("@playwright/test");
const { reseed, loginAdmin } = require("./helpers");

test.beforeEach(async ({ request }) => await reseed(request));

// /turf-monster-v2, the explainer that will become /about. Signed out on
// purpose: the notify-me form is for visitors with no account, so a spec that
// logged in first could not tell an open form from an authed one.
//
// TWO STATES, ONE SPEC, AND NO SKIP. The page counts down to
// NextSlateDrop::DROPS_AT (2026-10-20 14:00 UTC, 8:00 AM Mountain); after it
// the form gives way to "the slate is live". A date-gated test.skip would
// leave the executed set on that day and turn e2e_executed_set red for every
// PR, so the spec reads which state the SERVER drew and asserts that one.
// Rolling the page on to the next drop means moving that constant AND this.
const DROPS_AT = Date.parse("2026-10-20T14:00:00Z");

// The page's hooks are data-test (the attribute its integration tests scope
// to), not Playwright's default data-testid, so they are read as CSS.

test.describe("turf-monster-v2 explainer", () => {
  test("after the drop the page says the slate is live", async ({ page }) => {
    await page.goto("/turf-monster-v2");
    const live = page.locator('[data-test="v2-live"]');
    if (Date.now() < DROPS_AT - 60_000) {
      await expect(live).toBeHidden();
      await expect(page.locator('[data-test="v2-notify-form"]')).toBeVisible();
    } else if (Date.now() > DROPS_AT + 60_000) {
      await expect(live).toBeVisible();
      await expect(live).toContainText("The Weeks 7-9 slate is live");
    }
  });

  test("a visitor sees every section, signs up, and the row reaches the admin list", async ({ page, browser }) => {
    // The form exists only before the drop; after it this flow belongs to
    // the next slate, and the live-state test above carries the page.
    if (Date.now() >= DROPS_AT - 60_000) {
      await page.goto("/turf-monster-v2");
      await expect(page.locator('[data-test="v2-hero"]')).toContainText("Pick 6 teams.");
      return;
    }
    const email = `e2e-drop-${Date.now()}@example.com`;
    await page.goto("/turf-monster-v2");

    const root = page.locator('[data-test="turf-monster-v2"]');
    await expect(root.getByRole("heading", { level: 1 })).toHaveText("Pick 6 teams. Stack their points. Get paid.");
    await expect(page.locator('[data-test="v2-notify"]')).toContainText("Weeks 7-9 slate drops Tuesday morning");
    await expect(page.locator('[data-test="v2-how-to-play"]')).toContainText("How to play");
    await expect(page.locator('[data-test="v2-closing"]')).toContainText("Start playing");
    await expect(page.locator('[data-test="phone-mock"]')).toHaveCount(2);

    // The countdown is live: Alpine owns the numbers, and they are numbers.
    const days = page.locator('[data-test="v2-countdown"]').locator("[x-text=days]");
    await expect(days).toHaveText(/^\d+$/);

    // The hero CTA scrolls to the form.
    await page.locator('[data-test="v2-hero"]').getByRole("link", { name: "Get notified for Weeks 7-9" }).click();
    await expect(page).toHaveURL(/#notify$/);

    // A bad address first: the server's 422 must NOT read as success.
    const input = page.getByLabel("Notify me when Weeks 7-9 drops");
    await input.fill("not-an-email");
    await page.getByRole("button", { name: "Notify me" }).click();
    await expect(page.getByRole("alert")).toContainText("valid email");
    await expect(page.locator('[data-test="v2-notify-success"]')).toBeHidden();

    // Then a real one: success only after the server's 2xx.
    const answered = page.waitForResponse((res) => res.url().endsWith("/drop-signups") && res.request().method() === "POST");
    await input.fill(email);
    await page.getByRole("button", { name: "Notify me" }).click();
    expect((await answered).status()).toBe(200);
    await expect(page.locator('[data-test="v2-notify-success"]')).toBeVisible();
    await expect(page.locator('[data-test="v2-notify-success"]')).toContainText("You’re on the list.");

    // The row exists: read it where the operator will, on the admin list.
    const adminContext = await browser.newContext();
    const admin = await adminContext.newPage();
    await loginAdmin(admin);
    await admin.goto("/admin/drop_signups");
    await expect(admin.locator('[data-test="admin-drop-signups"]')).toContainText(email);
    await adminContext.close();
  });
});
