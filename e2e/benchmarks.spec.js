const { test, expect } = require("@playwright/test");
const { reseed } = require("./helpers");

test.beforeEach(async ({ request }) => await reseed(request));

// /benchmarks is the public pricing board — the "why does my team cost that?"
// page. NO login helper is called in this file on purpose: a signed-out visit
// is the thing under test, and a spec that logged in first could not tell a
// public page from an admin one. Seeded by e2e/seed.rb (NFL 2026 Weeks 4-6
// holds the six bye teams).
test.describe("benchmarks page", () => {
  test("a signed-out visitor sees the board, the bye line and the multipliers", async ({ page }) => {
    await page.goto("/benchmarks/nfl-2026-weeks-4-6");

    // Public: still on the page we asked for, not bounced to sign-in.
    await expect(page).toHaveURL(/\/benchmarks\/nfl-2026-weeks-4-6$/);
    await expect(page.getByRole("heading", { name: "Turf Score Benchmarks" })).toBeVisible();

    const rows = page.locator("tbody tr");
    await expect(rows).toHaveCount(32);
    await expect(page.getByTestId("benchmarks-two-line")).toContainText("plays 2 games, not 3");
    await expect(page.getByTestId("benchmarks-bye-badge")).toHaveCount(6);

    // Every price on the board is a real multiplier, and the bye teams are the
    // ones that can exceed the 2.0x full-span top.
    const prices = await rows.locator("td:last-child").allTextContents();
    expect(prices).toHaveLength(32);
    const byePrices = await page.locator("tbody tr", { has: page.getByTestId("benchmarks-bye-badge") })
      .locator("td:last-child").allTextContents();
    for (const text of byePrices) {
      const mult = parseFloat(text);
      expect(mult).toBeGreaterThanOrEqual(1.5);
      expect(mult).toBeLessThanOrEqual(3.0);
    }
  });

  test("it sends a reader to the rules for the formula itself", async ({ page }) => {
    await page.goto("/benchmarks/nfl-2026-weeks-4-6");
    await page.getByRole("link", { name: "How Turf Score works" }).click();

    await expect(page).toHaveURL(/turf-monster-v1/);
    await expect(page.getByText("Bye weeks", { exact: true })).toBeVisible();
  });
});
