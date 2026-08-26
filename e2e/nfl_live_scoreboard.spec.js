const { test, expect } = require("@playwright/test");
const { reseed, allowMotion } = require("./helpers");

// The league-wide live scoreboard at /live.
//
// What this proves that the Rails tests cannot: that a scoring event recorded
// on the SERVER reaches an already-open browser over the websocket, without a
// reload — the whole reason the page exists. The dev toolbar is the injector,
// standing in for a real NFL scoring play.
test.beforeEach(async ({ request }) => await reseed(request));

test.describe("Live NFL scoreboard", () => {
  test("renders the board without a sign-in", async ({ page }) => {
    await page.goto("/live");

    // Named, not `level: 1` — the navbar brand is also an h1, so an unnamed
    // level-1 lookup is a strict-mode violation rather than an assertion.
    await expect(page.getByRole("heading", { name: /Week 4/ })).toBeVisible();
    await expect(page.locator('[data-test="live-game-tile"]').first()).toBeVisible();
    // Public: no redirect to the sign-in screen.
    await expect(page).toHaveURL(/\/live$/);
  });

  test("a recorded score reaches an open page over the websocket", async ({ page }) => {
    await allowMotion(page);
    await page.goto("/live");

    // Pick the first team in the injector and read its CURRENT score off the
    // board, so the assertion is a delta rather than a hardcoded number.
    const select = page.locator('[data-test="dev-score-team"]');
    await expect(select).toBeVisible();
    const target = await select.locator("option").first().getAttribute("value");
    const [gameSlug, teamSlug] = target.split("|");

    const scoreCell = page
      .locator(`[data-game-slug="${gameSlug}"] [data-team-slug="${teamSlug}"] [data-role="score"]`);
    const before = parseInt((await scoreCell.textContent()).trim(), 10);

    await select.selectOption(target);
    await page.locator('[data-test="dev-score-touchdown"]').click();

    // NO reload anywhere in this test. If the score moves, the broadcast landed.
    await expect(scoreCell).toHaveText(String(before + 6), { timeout: 10000 });
  });

  test("a touchdown raises the scoring banner in the team's colors", async ({ page }) => {
    await allowMotion(page);
    await page.goto("/live");

    const select = page.locator('[data-test="dev-score-team"]');
    await select.selectOption({ index: 0 });
    await page.locator('[data-test="dev-score-touchdown"]').click();

    const banner = page.locator("#nfl-score-banner");
    await expect(banner).toBeVisible({ timeout: 10000 });
    await expect(page.locator("#nfl-score-label")).toHaveText("Touchdown");
    await expect(page.locator("#nfl-score-points")).toHaveText("+6");

    // The banner wears the scoring team's brand color, not a generic surface —
    // that is the point of reading Team#card_background into the feed node.
    const bg = await banner.evaluate((el) => getComputedStyle(el).backgroundColor);
    expect(bg).not.toBe("rgba(0, 0, 0, 0)");
    expect(bg).not.toBe("rgb(30, 41, 59)"); // the neutral used only for FINAL

    // A touchdown gets the TOUCHDOWN entrance, not a shared one. Asserted on the
    // class rather than on pixels because the whole point of five animations is
    // that they are five DIFFERENT ones, and a shared fallback would still look
    // fine in a screenshot.
    await expect(banner).toHaveClass(/nfl-b-td/);
  });

  test("the scoring team's row animates in its own colors and stays hot", async ({ page }) => {
    await allowMotion(page);
    await page.goto("/live");

    const select = page.locator('[data-test="dev-score-team"]');
    const target = await select.locator("option").first().getAttribute("value");
    const [gameSlug, teamSlug] = target.split("|");
    await select.selectOption(target);

    const row = page.locator(`[data-game-slug="${gameSlug}"] [data-team-slug="${teamSlug}"]`);
    // Both brand colours must reach the row: the field (washes, rail glow) and
    // the ink (the score). The ink is the fix for a score that rendered in a
    // team's near-black brand colour and vanished against the dark board.
    const field = await row.evaluate((el) => getComputedStyle(el).getPropertyValue("--nfl-team").trim());
    const ink = await row.evaluate((el) => getComputedStyle(el).getPropertyValue("--nfl-team-ink").trim());
    expect(field).toMatch(/^#/);
    expect(ink).toMatch(/^#/);
    expect(ink).not.toBe(field);

    await page.locator('[data-test="dev-score-field_goal"]').click();

    const score = row.locator('[data-role="score"]');
    // A field goal gets the FIELD GOAL score motion, and the number goes hot.
    await expect(score).toHaveClass(/nfl-s-fg/, { timeout: 10000 });
    await expect(score).toHaveClass(/nfl-score-hot/);

    // Hot means bold and in the team's ink — not the board's default grey. It
    // must OUTLIVE the banner, which is the whole reason the state is held in JS
    // and re-applied rather than left on a node the next broadcast replaces.
    await page.waitForTimeout(5000);
    const hot = await score.evaluate((el) => ({
      weight: getComputedStyle(el).fontWeight,
      color: getComputedStyle(el).color,
      still: el.classList.contains("nfl-score-hot")
    }));
    expect(hot.still).toBe(true);
    expect(Number(hot.weight)).toBeGreaterThanOrEqual(900);
    expect(hot.color).not.toBe("rgb(148, 163, 184)");
  });

  test("each scoring type is worth its own points", async ({ page }) => {
    await page.goto("/live");

    const select = page.locator('[data-test="dev-score-team"]');
    const target = await select.locator("option").first().getAttribute("value");
    const [gameSlug, teamSlug] = target.split("|");
    await select.selectOption(target);

    const scoreCell = page
      .locator(`[data-game-slug="${gameSlug}"] [data-team-slug="${teamSlug}"] [data-role="score"]`);
    const before = parseInt((await scoreCell.textContent()).trim(), 10);

    await page.locator('[data-test="dev-score-field_goal"]').click();
    await expect(scoreCell).toHaveText(String(before + 3), { timeout: 10000 });

    await page.locator('[data-test="dev-score-safety"]').click();
    await expect(scoreCell).toHaveText(String(before + 5), { timeout: 10000 });

    await page.locator('[data-test="dev-score-pat"]').click();
    await expect(scoreCell).toHaveText(String(before + 6), { timeout: 10000 });
  });

  test("clearing a game takes its score back to zero", async ({ page }) => {
    await page.goto("/live");

    const select = page.locator('[data-test="dev-score-team"]');
    const target = await select.locator("option").first().getAttribute("value");
    const [gameSlug, teamSlug] = target.split("|");
    await select.selectOption(target);

    const scoreCell = page
      .locator(`[data-game-slug="${gameSlug}"] [data-team-slug="${teamSlug}"] [data-role="score"]`);
    await page.locator('[data-test="dev-score-touchdown"]').click();
    await expect(scoreCell).not.toHaveText("0", { timeout: 10000 });

    await page.locator('[data-test="dev-score-clear"]').click();
    await expect(scoreCell).toHaveText("0", { timeout: 10000 });
  });
});
