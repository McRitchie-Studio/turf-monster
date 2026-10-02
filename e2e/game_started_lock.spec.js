const { test, expect } = require("@playwright/test");
const { reseed } = require("./helpers");

// THE LOCK ON A TEAM WHOSE GAME HAS STARTED, and where the contest URL sends
// you once one has.
//
// The lock used to be a glyph inside the card. It took a line of its own, so a
// locked card stood taller than its neighbours. It is now an overlay that
// floats over the card on hover and says why: "Game Started".
//
// The seed's span games are all weeks ahead, so the spec starts one through
// POST /test/set_game_kickoff and PUTS IT BACK afterwards — reseed does not
// rewrite games, and a started game left behind would route every later spec's
// visit to this contest onto the live board.
const CONTEST = "nfl-weeks-15-17";

let started;

test.beforeEach(async ({ request }) => {
  await reseed(request);
  const response = await request.post("/test/set_game_kickoff", { data: { contest: CONTEST } });
  expect(response.ok()).toBeTruthy();
  started = await response.json();
});

test.afterEach(async ({ request }) => {
  const response = await request.post("/test/set_game_kickoff", {
    data: { game_slug: started.game_slug, kickoff_at: started.previous_kickoff_at },
  });
  expect(response.ok()).toBeTruthy();
});

test.describe("a team whose game has started", () => {
  test("its card is exactly as tall as an unlocked card", async ({ page }) => {
    await page.goto(`/contests/${CONTEST}/contest`);

    const locked = page.locator(".holo-wrap:has(button.holo-card[disabled])").first();
    const open = page.locator(".holo-wrap:has(button.holo-card:not([disabled]))").first();
    await expect(locked).toBeVisible();
    await expect(open).toBeVisible();

    const lockedBox = await locked.locator("button.holo-card").boundingBox();
    const openBox = await open.locator("button.holo-card").boundingBox();
    expect(lockedBox.height).toBe(openBox.height);
  });

  test("hovering it floats the lock and Game Started over the middle of the card", async ({ page }) => {
    await page.goto(`/contests/${CONTEST}/contest`);

    const locked = page.locator(".holo-wrap:has(button.holo-card[disabled])").first();
    const overlay = locked.locator("[data-test='game-started-overlay']");
    await locked.scrollIntoViewIfNeeded();

    // Present but invisible until hover. Opacity, not toBeVisible(): Playwright
    // counts an opacity:0 element as visible.
    await expect(overlay).toHaveCSS("opacity", "0");

    await locked.hover();
    await expect(overlay).toHaveCSS("opacity", "1");
    await expect(overlay).toContainText("Game Started");
    await expect(overlay).toContainText("🔒");

    // Centred on the card: the text block's midpoint is the card's midpoint.
    const card = await locked.locator("button.holo-card").boundingBox();
    const label = await overlay.getByText("Game Started").boundingBox();
    const cardMidX = card.x + card.width / 2;
    const labelMidX = label.x + label.width / 2;
    expect(Math.abs(cardMidX - labelMidX)).toBeLessThan(2);
    expect(label.y).toBeGreaterThan(card.y + card.height * 0.25);
    expect(label.y + label.height).toBeLessThan(card.y + card.height * 0.85);

    // An unlocked card has no overlay to show.
    const open = page.locator(".holo-wrap:has(button.holo-card:not([disabled]))").first();
    await expect(open.locator("[data-test='game-started-overlay']")).toHaveCount(0);
  });
});

test.describe("the contest URL once a game has started", () => {
  test("routes to the live board, and ← Contest comes back to the contest page", async ({ page }) => {
    await page.goto(`/contests/${CONTEST}`);
    await expect(page).toHaveURL(new RegExp(`/contests/${CONTEST}/live$`));

    await page.getByRole("link", { name: "← Contest" }).click();

    // The contest page, at its own address — not bounced back to live.
    await expect(page).toHaveURL(new RegExp(`/contests/${CONTEST}/contest$`));
    await expect(page.locator("button.holo-card").first()).toBeVisible();
  });
});
