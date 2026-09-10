const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

test.beforeEach(async ({ request }) => await reseed(request));

// The soccer formula report renders live samples straight off db:seed — the
// seed caches the checked-in 2026 World Cup DK team-total odds onto the
// fifa-slate matchups (Soccer::CacheTeamTotalOdds), so the iteration tables
// and charts carry real rows, not the empty static shell.
test.describe("formula report seeded samples", () => {
  test("admin sees odds-backed sample rows and populated charts", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/slates/formula_report");

    await expect(page.getByRole("heading", { name: "DK Score Formula — Iterations" })).toBeVisible();

    // The V1 iteration table renders one row per odds-bearing matchup.
    const v1Table = page.locator("table").first();
    const rowCount = await v1Table.locator("tbody tr").count();
    expect(rowCount).toBeGreaterThan(0);

    // Sample rows carry an odds column (a signed American price), so the
    // sample really came from the seeded odds, not a line-only row.
    await expect(v1Table.locator("tbody td", { hasText: /^[+-]\d{3}/ }).first()).toBeVisible();

    // The playground data is populated too — the chart has rows to draw.
    const playgroundRows = await page.evaluate(() => window._playgroundMatchups.length);
    expect(playgroundRows).toBeGreaterThan(0);
  });
});
