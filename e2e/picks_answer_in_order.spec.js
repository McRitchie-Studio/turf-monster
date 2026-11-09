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
const CLEAR = "/clear_picks";
const CARDS = '[x-data*="selectionBoard"] button[role="checkbox"]:not([disabled])';

// The slip's own count: the "Clear n / 6" chip. Its text, not the page's, so no other "n / 6" can answer.
const slipCount = (page) => page.getByRole("button", { name: "Clear all picks" }).locator("visible=true").first();

// The server's cart as this page was rendered with it: #board-config's cartSelections.
const serverCart = (page) =>
  page.evaluate(() => Object.keys(JSON.parse(document.getElementById("board-config").textContent).cartSelections).length);

test.beforeEach(async ({ request }) => await reseed(request));

// Signed in on the contest, with an empty cart, and every pick save (and Clear) counted as it goes out and as it is answered.
async function emptyBoard(page) {
  await loginAdmin(page);
  await page.goto(CONTEST);
  await page.waitForLoadState("networkidle");
  await page.evaluate(async (contest) => {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
    await fetch(`${contest}/clear_picks`, { method: "POST", headers: { "X-CSRF-Token": csrfToken, Accept: "application/json" } });
  }, CONTEST);
  await page.reload();
  await page.waitForLoadState("networkidle");

  const saves = (req) => req.url().endsWith(TOGGLE) || req.url().endsWith(CLEAR);
  const sent = [];
  const answered = [];
  page.on("request", (req) => saves(req) && sent.push(req));
  page.on("requestfinished", (req) => saves(req) && answered.push(req));
  return { sent, answered };
}

test("an earlier pick's late answer does not drop the picks after it", async ({ page }) => {
  const { sent, answered } = await emptyBoard(page);

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

  const cards = page.locator(CARDS);
  for (let i = 0; i < 5; i += 1) {
    await cards.nth(i).click();
    await expect(slipCount(page)).toHaveText(new RegExp(`Clear\\s*${i + 1}\\s*/\\s*6`));
  }

  // Only the held answer is outstanding: every other toggle sent so far is answered.
  await expect.poll(() => sent.length - answered.length).toBe(1);
  release();
  await expect.poll(() => answered.length).toBe(5);

  await expect(slipCount(page)).toHaveText(/Clear\s*5\s*\/\s*6/);
  await page.unroute(`**${TOGGLE}`);
  await page.reload();
  expect(await serverCart(page)).toBe(5);
  await expect(slipCount(page)).toHaveText(/Clear\s*5\s*\/\s*6/);
});

// Clear rides the same queue. Pick saves still waiting when Clear is tapped land
// FIRST, then the clear: the cart ends empty on the server, and no pick's answer
// puts a pick back in the slip.
test("Clear after fast picks leaves the cart empty, on the page and on the server", async ({ page }) => {
  const { sent, answered } = await emptyBoard(page);

  // The first pick's answer waits (the server has already applied it), so the
  // picks after it queue behind it, as they do on a slow connection.
  let release;
  const released = new Promise((resolve) => (release = resolve));
  let seen = 0;
  await page.route(`**${TOGGLE}`, async (route) => {
    seen += 1;
    if (seen !== 1) return route.continue();
    const response = await route.fetch();
    await released;
    await route.fulfill({ response });
  });

  const cards = page.locator(CARDS);
  for (let i = 0; i < 4; i += 1) {
    await cards.nth(i).click();
    await expect(slipCount(page)).toHaveText(new RegExp(`Clear\\s*${i + 1}\\s*/\\s*6`));
  }
  await slipCount(page).click();
  await expect(slipCount(page)).toBeHidden();

  release();
  // Four pick saves and the clear, every one answered.
  await expect.poll(() => answered.length).toBe(5);
  expect(sent.length).toBe(5);
  // Every answer is in, so the slip's count is the board's last word: read it, not a hidden chip.
  expect(await page.evaluate(() => window.Alpine.$data(document.querySelector('[x-data*="selectionBoard"]')).selectionCount)).toBe(0);

  await page.unroute(`**${TOGGLE}`);
  await page.reload();
  expect(await serverCart(page), "a pick saved before Clear reached the server after it").toBe(0);
});
