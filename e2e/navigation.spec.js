const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// ---------------------------------------------------------------------------
// Page navigation — verify key pages load without errors
//
// The lightweight page-load checks are tagged @smoke: they are core navigation
// in the fast "general" e2e lane (`npm run test:smoke` / `--grep @smoke`). The
// login-driven gear-sidebar back-nav loop below is intentionally LEFT OUT of
// @smoke — it's heavier and belongs to the comprehensive lane. See
// docs/LOCAL_STACK.md "Two e2e lanes".
// ---------------------------------------------------------------------------

test("teams page loads @smoke", async ({ page }) => {
  await page.goto("/teams");
  await expect(page.locator("body")).toBeVisible();
  // Should have some team content from seeds
  await expect(page.locator("body")).toContainText(/team/i);
});

test("games page loads @smoke", async ({ page }) => {
  await page.goto("/games");
  await expect(page.locator("body")).toBeVisible();
});

test("signin page loads with magic-link + wallet options @smoke", async ({ page }) => {
  await page.goto("/signin");
  await expect(page.locator('input[name="email"]')).toBeVisible();
  // Passwordless now — email magic link + Google + wallet hub, no password.
  await expect(page.locator('input[name="password"]')).toHaveCount(0);
  await expect(page.getByRole("button", { name: "Email Link" })).toBeVisible();
  await expect(page.locator('button:has-text("Google")')).toBeVisible();
  await expect(page.locator('button:has-text("Solana")')).toBeVisible();
});

// Unified auth: /login + /signup are one create-or-login flow, so they both
// 301-redirect to the canonical /signin page.
test("legacy /login + /signup redirect to /signin @smoke", async ({ page }) => {
  await page.goto("/login");
  await expect(page).toHaveURL(/\/signin/);

  await page.goto("/signup");
  await expect(page).toHaveURL(/\/signin/);
  await expect(page.getByRole("button", { name: "Email Link" })).toBeVisible();
});

test("error logs page loads @smoke", async ({ page }) => {
  await page.goto("/error_logs");
  await expect(page.locator("body")).toBeVisible();
});

test("turf totals page loads @smoke", async ({ page }) => {
  await page.goto("/turf-totals-v1");
  await expect(page.locator("body")).toBeVisible();
});

// The NFL rules page, and the one the navbar's Rules link now lands on. Both
// versioned rules pages stay smoked: they are one per SEASON, not a page and a
// replacement, and the older route must keep answering old links.
test("turf monster rules page loads @smoke", async ({ page }) => {
  await page.goto("/turf-monster-v1");
  await expect(page.locator("body")).toBeVisible();
  // Title, not getByRole("heading", { level: 1 }) — the navbar wordmark is an
  // h1 too (_navbar.html.erb), so a level-1 heading locator matches TWO nodes
  // and dies on strict mode. The title is the page's own, and unambiguous.
  await expect(page).toHaveTitle(/Turf Monster v1/);
});

const signedInSidebarRoutes = [
  { route: "/contests", destination: "/account" },
  { route: "/account", destination: "/contests" },
  { route: "/contests/my", destination: "/account" },
];

const gearSidebarTriggers = [
  "button[data-gear-sidebar-trigger]",
  "button[data-username-display]",
  "button[data-profile-image-toggle]",
];

for (const { route, destination } of signedInSidebarRoutes) {
  test(`gear sidebar reopens after browser back from ${route}`, async ({ page, request }) => {
    await reseed(request);
    await loginAdmin(page);
    await page.goto(route);
    await page.waitForFunction(() => window.Alpine && Alpine.store("sidebars"));

    await page.locator("button[data-gear-sidebar-trigger]").first().click();
    await expect(page.locator("#gear-sidebar")).toBeVisible();

    await page.locator(`#gear-sidebar a[href="${destination}"]`).first().click();
    await expect(page).toHaveURL(destination, { timeout: 15_000 });

    await page.goBack();
    await expect(page).toHaveURL(route);
    await page.waitForFunction(() => window.Alpine && Alpine.store("sidebars"));

    for (const trigger of gearSidebarTriggers) {
      await page.locator(trigger).first().click();
      await expect(page.locator("#gear-sidebar")).toBeVisible();
      await page.keyboard.press("Escape");
      await expect(page.locator("#gear-sidebar")).toBeHidden();
    }
  });
}
