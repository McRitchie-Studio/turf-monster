const { test, expect } = require("@playwright/test");

// /teams is public. Each card wears its own team field (disposition-based), and
// lists its palette on a translucent strip in four families — Dark / Alt /
// Light / Grey — as click-to-copy swatches (the hex rides the aria-label). This
// guards the whole vertical: seeded colors → DB → view swatches → Alpine filter.
test.describe("Teams palette", () => {
  test("shows each team's palette and filters to NFL @smoke", async ({ page }) => {
    await page.goto("/teams");

    // Intro documents the click-to-copy family strip.
    await expect(page.getByText("click any swatch to copy its hex")).toBeVisible();

    // Bills wear their brand colors as copy-able swatches; the aria-label carries
    // the hex — dark #00338D + dark-alt #041E42, light #C60C30 + light-alt #FFFFFF.
    const bills = page.locator("[data-team-card]", { hasText: "Buffalo Bills" });
    await expect(bills.locator('button[aria-label="Copy #00338D"]')).toBeVisible();
    await expect(bills.locator('button[aria-label="Copy #041E42"]')).toBeVisible();
    await expect(bills.locator('button[aria-label="Copy #C60C30"]')).toBeVisible();
    await expect(bills.locator('button[aria-label="Copy #FFFFFF"]')).toBeVisible();

    // The NFL pill narrows the grid to the 32 NFL teams.
    await page.getByRole("button", { name: "NFL", exact: true }).click();
    await expect(page.locator('[data-team-card][data-league="fifa"]:visible')).toHaveCount(0);
    await expect(page.locator('[data-team-card][data-league="nfl"]:visible')).toHaveCount(32);
  });
});
