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
    await expect(root.getByRole("heading", { level: 1 })).toHaveText("Pick 6 teams. Stack points. Get paid.");
    await expect(page.locator('[data-test="v2-notify"]')).toContainText("Weeks 7-9 slate drops Tuesday morning");
    await expect(page.locator('[data-test="v2-how-to-play"]')).toContainText("How to play");
    await expect(page.locator('[data-test="v2-closing-cta"]')).toHaveCount(1);
    await expect(page.locator('[data-test="phone-mock"]')).toHaveCount(2);
    // The hero phone shows the six showcase teams, and no opponent chip is
    // cut to an ellipsis: each is a 2-3 letter abbreviation.
    const board = page.locator('[data-test="phone-pick-board"]');
    for (const name of ["49ers", "Rams", "Cowboys", "Seahawks", "Vikings", "Saints"]) {
      await expect(board).toContainText(name);
    }
    const chips = await board.locator('[data-test="opponent-abbr"]').allTextContents();
    expect(chips).toHaveLength(18);
    for (const chip of chips) expect(chip.trim()).toMatch(/^[A-Z0-9]{2,3}$/);
    // The board's label, not the rules page's: "1.1x Points".
    await expect(board.locator('[data-test="multiplier-label"]')).toHaveText(Array(6).fill("Points"));
    await expect(board).not.toContainText("Turf Score");

    // The countdown is live: Alpine owns the numbers, and they are numbers.
    const countdown = page.locator('[data-test="v2-countdown"]');
    await expect(countdown.locator("[x-text=days]")).toHaveText(/^\d+$/);
    for (const unit of ["hours", "minutes", "seconds"]) {
      await expect(countdown.locator(`[x-text=${unit}]`)).toHaveText(/^\d{2}$/);
    }
    // It visibly moves: the seconds tile changes within two seconds.
    const seconds = countdown.locator("[x-text=seconds]");
    const before = await seconds.textContent();
    await expect(seconds).not.toHaveText(before, { timeout: 2500 });

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

  // The laptop behind the phone draws from xl up and is gone on a phone.
  test("the hero laptop shows at desktop width and is hidden at 375", async ({ page }) => {
    await page.setViewportSize({ width: 1280, height: 900 });
    await page.goto("/turf-monster-v2");
    const laptop = page.locator('[data-test="laptop-mock"]');
    await expect(laptop).toBeVisible();
    await expect(laptop.locator('[data-test="laptop-lobby"]')).toContainText("Contests");
    expect(await page.evaluate(() => document.documentElement.scrollWidth === document.documentElement.clientWidth)).toBe(true);

    await page.setViewportSize({ width: 375, height: 800 });
    await expect(laptop).toBeHidden();
    await expect(page.locator('[data-test="v2-hero"] [data-test="phone-mock"]')).toBeVisible();
    expect(await page.evaluate(() => document.documentElement.scrollWidth === document.documentElement.clientWidth)).toBe(true);
  });

  // THE ONE CTA WITH NOTHING TO ENTER. The e2e seed always has open contests,
  // so the spec holds them (coming_soon) for its own duration and releases
  // exactly those afterwards, pass or fail: rows outlive a spec here.
  test.describe("with no contest open to enter", () => {
    let held = [];
    test.beforeEach(async ({ request }) => {
      const res = await request.post("/test/hold_open_contests", { data: { hold: "true" } });
      held = (await res.json()).held;
    });
    test.afterEach(async ({ request }) => {
      await request.post("/test/hold_open_contests", { data: { hold: "false", slugs: held } });
    });

    test("the hero CTA opens the notify modal, which ticks and signs a visitor up", async ({ page }) => {
      await page.goto("/turf-monster-v2?reference=e2e-modal");
      const cta = page.locator('[data-test="v2-hero-cta"]');
      await expect(cta).toHaveText("Play Turf Monster");
      if (Date.now() >= DROPS_AT - 60_000) return; // after the drop the modal says "live" instead

      await cta.click();
      const dialog = page.getByRole("dialog", { name: "Get notified when Weeks 7-9 drops" });
      await expect(dialog).toBeVisible();
      const modal = dialog.locator('[data-test="drop-modal"]');
      const seconds = modal.locator("[x-text=seconds]");
      await expect(seconds).toHaveText(/^\d{2}$/);
      const before = await seconds.textContent();
      await expect(seconds).not.toHaveText(before, { timeout: 2500 });

      const answered = page.waitForResponse((res) => res.url().endsWith("/drop-signups") && res.request().method() === "POST");
      await modal.getByLabel("Notify me when Weeks 7-9 drops").fill(`e2e-modal-${Date.now()}@example.com`);
      await modal.getByRole("button", { name: "Notify me" }).click();
      expect((await answered).status()).toBe(200);
      await expect(modal.locator('[data-test="drop-modal-success"]')).toContainText("You’re on the list.");

      // Esc closes it.
      await page.keyboard.press("Escape");
      await expect(dialog).toBeHidden();
    });
  });
});
