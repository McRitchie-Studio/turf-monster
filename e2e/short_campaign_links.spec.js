const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] A campaign short link, end to end, the way it is used: an admin makes
// /l/<name> in /admin/short_links, a stranger's browser opens it and lands on
// /turf-monster-v2 tagged ?r=<reference>, and the click reads back as ONE on
// both /admin/short_links and /admin/referrals.
//
// What only a browser proves: the /l/ hop sets the visitor cookie and the
// browser carries it through a real 302 to the landing, which is what lets the
// landing record the click at once instead of parking it (the integration
// suite fakes the cookie jar). A second open of the same link is the same
// visitor and must not count again.
//
// The name and reference are unique per run, not "tt": reseed does not reset
// rows between specs or runs, and a short link name can be made only once.
//
// A desktop Chrome UA, not Playwright's default: "HeadlessChrome" is a bot by
// ReferralVisit's own rule.
const DESKTOP_CHROME =
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/129.0.0.0 Safari/537.36";

test.use({ userAgent: DESKTOP_CHROME });
test.beforeEach(async ({ request }) => await reseed(request));

test("a short link lands on its page and counts one click under its reference", async ({ page, browser, baseURL }) => {
  const stamp = Date.now().toString(36);
  const name = `tt-${stamp}`;
  const reference = `tiktok-bio-${stamp}`;

  // The admin makes the link.
  await loginAdmin(page);
  await page.goto("/admin/short_links/new");
  await page.getByLabel("Name").fill(name.toUpperCase()); // stored lowercase
  await page.getByLabel("Goes to").fill("/turf-monster-v2");
  await page.getByLabel("Reference").fill(reference);
  await page.getByRole("button", { name: "Create Short Link" }).click();
  await expect(page).toHaveURL(/\/admin\/short_links$/);
  const adminRow = page.locator(`[data-short-link="${name}"]`);
  await expect(adminRow.locator("[data-copy-text]")).toHaveAttribute("data-copy-text", `${baseURL}/l/${name}`);
  await expect(adminRow.locator("[data-clicks]")).toHaveText("0");

  // A stranger opens it: a fresh browser with no cookies at all.
  const visitor = await browser.newContext({ baseURL, userAgent: DESKTOP_CHROME });
  const tab = await visitor.newPage();
  await tab.goto(`/l/${name}`);
  await expect(tab).toHaveURL(`${baseURL}/turf-monster-v2?r=${reference}`);
  await expect(tab.locator("h1").first()).toBeVisible();
  await tab.goto(`/l/${name}`); // the same visitor again: must not count twice
  await expect(tab).toHaveURL(`${baseURL}/turf-monster-v2?r=${reference}`);
  await visitor.close();

  // The admin reads one click back, on both pages.
  await page.goto("/admin/short_links");
  await expect(adminRow.locator("[data-clicks]")).toHaveText("1");

  await page.goto("/admin/referrals?days=7");
  const row = page.locator(`[data-reference-row="${reference}"]`);
  await expect(row.locator('[data-cell="clicks"]')).toHaveText("1");
  await expect(row.locator('[data-cell="visitors"]')).toHaveText("1");
});
