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

// A VISITOR ON THEIR WAY BACK TO FINISH AN ENTRY IS NOT SENT TO THE LIVE BOARD.
//
// The board saves the cart to localStorage before a full-page sign-in (the
// Google redirect when the popup is blocked) and replays it when the visitor
// returns. They return through root or the bare contest URL — both of which
// route to the live board once a game has started, and the live board has no
// entry board to replay into. So the live page hands a fresh cart for THIS
// contest back to the contest page. Review caught the first version of the
// router stranding exactly this visitor.
//
// The cart is saved by the board's own saveCartForRedirect, not a hand-written
// blob, so the spec cannot drift from the shape the board really writes.
test.describe("a saved cart, once a game has started", () => {
  async function saveCart(page) {
    await page.goto(`/contests/${CONTEST}/contest`);
    const card = page.locator("button.holo-card:not([disabled])").first();
    const picked = (await card.locator(".team-name").innerText()).trim();
    await card.click();
    await expect(card).toHaveAttribute("aria-checked", "true");
    await page.evaluate(() => {
      const board = document.querySelector('[x-data="selectionBoard()"]');
      window.Alpine.$data(board).saveCartForRedirect(true);
    });
    return picked;
  }

  for (const [label, path] of [["the bare contest URL", `/contests/${CONTEST}`], ["the live board itself", `/contests/${CONTEST}/live`]]) {
    test(`returning through ${label} lands on the contest page with the lineup restored`, async ({ page }) => {
      const picked = await saveCart(page);

      await page.goto(path);

      await expect(page).toHaveURL(new RegExp(`/contests/${CONTEST}/contest$`));
      const card = page.locator("button.holo-card", { has: page.locator(".team-name", { hasText: picked }) }).first();
      await expect(card).toHaveAttribute("aria-checked", "true");
    });
  }

  // Root is not walked here: which contest root features depends on the seed.
  // It is pinned in two halves instead — root redirects to this live board
  // (test/controllers/contest_router_test.rb), and the live board hands the cart
  // back (the test above).

  test("a stale cart, or one for another contest, leaves the visitor on the live board", async ({ page }) => {
    await saveCart(page);
    await page.evaluate(() => {
      const cart = JSON.parse(localStorage.getItem("pendingContestEntry"));
      cart.savedAt = Date.now() - 31 * 60 * 1000;
      localStorage.setItem("pendingContestEntry", JSON.stringify(cart));
    });
    await page.goto(`/contests/${CONTEST}`);
    await expect(page.locator("[data-test='live-state']")).toBeVisible();
    await expect(page).toHaveURL(new RegExp(`/contests/${CONTEST}/live$`));

    await page.evaluate(() => {
      localStorage.setItem("pendingContestEntry", JSON.stringify({ contestSlug: "some-other-contest", selections: { 1: true }, autoEnter: true, savedAt: Date.now() }));
    });
    await page.goto(`/contests/${CONTEST}`);
    await expect(page.locator("[data-test='live-state']")).toBeVisible();
    await expect(page).toHaveURL(new RegExp(`/contests/${CONTEST}/live$`));
  });

  test("leaving edit mode never needs the router: the board's own exits name the contest page", async ({ page }) => {
    await page.goto(`/contests/${CONTEST}/contest`);
    const html = await page.content();
    expect(html).toContain("'/contests/' + this.contestId + '/contest'");
    expect(html).not.toContain("window.location.href = '/contests/' + this.contestId;");
  });
});
