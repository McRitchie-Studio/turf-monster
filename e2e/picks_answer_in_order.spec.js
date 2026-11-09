const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// Picks made faster than the server answers all stay in the slip
// (task ci-cause-turf-monster-e2e-glass-surfaces-spec-js).
//
// Each pick POSTs toggle_selection, and the board adopts the server's answer as
// the truth. That answer is the cart as it stood when THAT request ran. With the
// POSTs in flight together, an earlier pick's answer could land after a later
// pick's, and adopting it last threw the later picks away: in CI the glass spec's
// slip fell from 5 / 6 back to 3 / 6 and stayed there.
//
// This spec makes that order certain instead of rare. It holds the third pick's
// answer (the server has already applied it) until every other toggle the page
// has sent is answered, then lets it land. The cart must still hold all five,
// in the slip and on the server.
const CONTEST = "/contests/world-cup-2026";
const TOGGLE = "/toggle_selection";

test.beforeEach(async ({ request }) => await reseed(request));

test("an earlier pick's late answer does not drop the picks after it", async ({ page }) => {
  await loginAdmin(page);
  await page.goto(CONTEST);
  await page.waitForLoadState("networkidle");
  await page.evaluate(async (contest) => {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
    await fetch(`${contest}/clear_picks`, { method: "POST", headers: { "X-CSRF-Token": csrfToken, Accept: "application/json" } });
  }, CONTEST);
  await page.reload();
  await page.waitForLoadState("networkidle");

  const sent = [];
  const answered = [];
  page.on("request", (req) => req.url().endsWith(TOGGLE) && sent.push(req));
  page.on("requestfinished", (req) => req.url().endsWith(TOGGLE) && answered.push(req));

  let release;
  const released = new Promise((resolve) => (release = resolve));
  let seen = 0;
  await page.route(`**${TOGGLE}`, async (route) => {
    seen += 1;
    if (seen !== 3) return route.continue();
    const response = await route.fetch(); // the server has applied the third pick
    await released;
    await route.fulfill({ response });
  });

  const slip = page.locator("body");
  const cards = page.locator('[x-data*="selectionBoard"] button[role="checkbox"]:not([disabled])');
  for (let i = 0; i < 5; i += 1) {
    await cards.nth(i).click();
    await expect(slip).toContainText(`${i + 1} / 6`);
  }

  // Only the held answer is outstanding: every other toggle sent so far is answered.
  await expect.poll(() => sent.length - answered.length).toBe(1);
  release();
  await expect.poll(() => answered.length).toBe(5);

  await expect(slip).toContainText("5 / 6");
  await page.unroute(`**${TOGGLE}`);
  await page.reload();
  await expect(page.locator("body")).toContainText("5 / 6");
});
