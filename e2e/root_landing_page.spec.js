const { test, expect } = require("@playwright/test");
const { login, reseed } = require("./helpers");

// Root serves the LANDING PAGE (/tasks/turf-root-serves-landing-page). "/" is
// the turf_monster_v2 explainer for a signed-out visitor; a signed-in visitor
// goes on to the lobby, which lives at /contests. The sign-in return flows
// that used to land on "/" because "/" was the lobby must still end on the
// lobby, and the lobby must still hand a saved cart back to its contest.

const LANDING = "[data-test='turf-monster-v2']";
const LOBBY_HEADING = "h1:has-text('Contests')";
const PROBE = "root-landing-handback-probe";

// A contest page stand-in, so the hand-back is observable without a contest
// in any particular state: the cart names PROBE, and its page is stubbed.
async function stubProbePage(page) {
  await page.route(`**/contests/${PROBE}/contest`, (route) =>
    route.fulfill({ contentType: "text/html", body: "<p id='handed-back'>contest page</p>" }));
}

async function saveCart(page) {
  await page.goto("/help"); // a page that renders no hand-back of its own
  await page.evaluate((slug) => {
    localStorage.setItem("pendingContestEntry",
      JSON.stringify({ contestSlug: slug, selections: { 1: true }, autoEnter: true, savedAt: Date.now() }));
  }, PROBE);
}

test.beforeEach(async ({ request }) => await reseed(request));

test("a signed-out visitor at / sees the landing page, not the lobby", async ({ page }) => {
  await page.goto("/");
  await expect(page.locator(LANDING)).toBeVisible();
  await expect(page).toHaveURL(/\/$/);
  await expect(page.locator(LOBBY_HEADING)).toHaveCount(0);
});

test("control: /contests is the lobby, not the landing page", async ({ page }) => {
  await page.goto("/contests");
  await expect(page.locator(LOBBY_HEADING)).toBeVisible();
  await expect(page.locator(LANDING)).toHaveCount(0);
});

test("the retired World Cup path lands a signed-out visitor on the landing page", async ({ page }) => {
  await page.goto("/world-cup");
  await expect(page).toHaveURL(/\/$/);
  await expect(page.locator(LANDING)).toBeVisible();
});

test("a magic link with no destination lands on the lobby, and / takes a signed-in user there", async ({ page }) => {
  await login(page, `root-lp-${Date.now().toString(36)}@example.com`);
  await expect(page).toHaveURL(/\/contests$/);
  await expect(page.locator(LOBBY_HEADING)).toBeVisible();

  await page.goto("/");
  await expect(page).toHaveURL(/\/contests$/);
  await expect(page.locator(LOBBY_HEADING)).toBeVisible();
  await expect(page.locator(LANDING)).toHaveCount(0);
});

test("a guest mid-entry who signs in is handed back to the contest their cart names", async ({ page }) => {
  await stubProbePage(page);
  await saveCart(page);

  await page.request.post("/test/magic_link_token", { data: { email: `root-cart-${Date.now().toString(36)}@example.com` } })
    .then(async (resp) => page.goto((await resp.json()).url));
  await expect(page.locator("#handed-back")).toBeVisible();
  await expect(page).toHaveURL(new RegExp(`/contests/${PROBE}/contest$`));
});

test("a signed-out guest holding a cart at / is handed back once, as the lobby root did", async ({ page }) => {
  await stubProbePage(page);
  await saveCart(page);

  await page.goto("/");
  await expect(page.locator("#handed-back")).toBeVisible();

  // ONE hand-off per cart: the next visit to / stays on the landing.
  await page.goto("/");
  await expect(page.locator(LANDING)).toBeVisible();
});
