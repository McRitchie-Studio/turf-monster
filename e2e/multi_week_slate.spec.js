const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

test.beforeEach(async ({ request }) => await reseed(request));

// A Slate is a POOL OF GAMES, not one NFL week. "NFL 2026 Weeks 1-3" holds three
// games per team, and each team is ranked on its SUMMED expected points — so the
// page must show 32 team rows, not 96 matchup rows. Seeded by e2e/seed.rb.
test.describe("multi-week slate page", () => {
  test("ranks teams, not matchup rows", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/slates/nfl-2026-weeks-1-3");

    const rows = page.locator("div.sortable-item");
    await expect(rows).toHaveCount(32);
  });

  test("a team row sums its three games and lists all three opponents", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/slates/nfl-2026-weeks-1-3");

    const topRow = page.locator("div.sortable-item").first();

    // Three opponents, slash-joined — the team faces a different one each week.
    await expect(topRow).toContainText(/vs\s+\w+\s*\/\s*\w+\s*\/\s*\w+/);

    // The DK total is a THREE-game sum, so it clears any single-game figure by a
    // wide margin (one NFL team-total is ~20-30).
    const dkText = await topRow.innerText();
    const dk = parseFloat(dkText.match(/DK\s+([0-9.]+)/)[1]);
    expect(dk).toBeGreaterThan(50);

    // Rank 1 always earns exactly the 1.0x floor.
    await expect(topRow).toContainText("1.0x");
  });

  test("a single-week slate still renders one row per team", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/slates/nfl-2026-week-1");

    // Same 32 teams, but one game each — the regression that matters is that
    // nothing about the one-week page changed.
    await expect(page.locator("div.sortable-item")).toHaveCount(32);

    const topRow = page.locator("div.sortable-item").first();
    const dk = parseFloat((await topRow.innerText()).match(/DK\s+([0-9.]+)/)[1]);
    expect(dk).toBeLessThan(50);
  });
});
