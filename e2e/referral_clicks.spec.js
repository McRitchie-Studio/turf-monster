const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] A click on a trackable link shows up on the admin report.
//
// What only a browser proves: the visitor cookie a real browser keeps is what
// dedupes the reload below (the integration suite fakes the cookie jar), and
// the click is counted from the page a person actually opens, then read back
// through the report an operator actually reads.
//
// The reference is unique per run because reseed does not reset rows between
// specs, and a second run the same day in a fresh browser is a second visitor.
//
// A desktop Chrome UA, not Playwright's default: "HeadlessChrome" is a bot by
// ReferralVisit's own rule, and that rule is the thing under test, not a hurdle.
const DESKTOP_CHROME =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";

test.use({ userAgent: DESKTOP_CHROME });
test.beforeEach(async ({ request }) => await reseed(request));

test("a ?reference= visit counts once and shows on /admin/referrals", async ({ page }) => {
  const reference = `tiktok-e2e-${Date.now()}`;

  await page.goto(`/?reference=${reference}`);
  await page.reload(); // same visitor, same day: still one click

  await loginAdmin(page);
  await page.goto("/admin/referrals?days=7");

  const row = page.locator(`[data-reference-row="${reference}"]`);
  await expect(row).toBeVisible();
  await expect(row.locator('[data-cell="clicks"]')).toHaveText("1");
  await expect(row.locator('[data-cell="visitors"]')).toHaveText("1");

  // The per-day table opens from the row.
  await row.getByRole("link", { name: reference }).click();
  await expect(page.locator(`[data-referral-daily="${reference}"]`)).toBeVisible();
});
