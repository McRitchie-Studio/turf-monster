const { test, expect } = require("@playwright/test");

// The navbar geo badge is PUBLIC — it renders for a signed-out visitor,
// because detection is IP-based (every request runs detect_geo_state). This
// asserts structure only, never a specific state: locally the dev fallback
// resolves (DEV_GEO_STATE), elsewhere the badge may legitimately read "??".
test.describe("Geo badge (signed out)", () => {
  test("the navbar shows the location badge without signing in", async ({ page }) => {
    await page.goto("/contests");

    const badge = page.locator("nav .geo-badge").first();
    await expect(badge).toBeVisible();
    await expect(badge).toHaveText(/^\s*([A-Z]{2}|\?\?)\s*$/);
  });
});
