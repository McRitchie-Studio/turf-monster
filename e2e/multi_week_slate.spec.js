const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

test.beforeEach(async ({ request }) => await reseed(request));

// A Slate is a POOL OF GAMES, not one NFL week. "NFL 2026 Weeks 1-3" holds three
// games per team, and each team is ranked on its expected points PER GAME across
// them — so the page must show 32 team rows, not 96 matchup rows. Seeded by
// e2e/seed.rb.
test.describe("multi-week slate page", () => {
  test("ranks teams, not matchup rows", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/slates/nfl-2026-weeks-1-3");

    const rows = page.locator("div.sortable-item");
    await expect(rows).toHaveCount(32);
  });

  test("a team row sums its three games and lists all three opponents", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/slates/nfl-2026-weeks-1-3");

    const topRow = page.locator("div.sortable-item").first();

    // Three opponents, slash-joined — the team faces a different one each week.
    await expect(topRow).toContainText(/vs\s+\w+\s*\/\s*\w+\s*\/\s*\w+/);

    // The DK total is a THREE-game sum, so it clears any single-game figure by a
    // wide margin (one NFL team-total is ~20-30).
    const dkText = await topRow.innerText();
    const dk = parseFloat(dkText.match(/DK\s+([0-9.]+)/)[1]);
    expect(dk).toBeGreaterThan(50);

    // Rank 1 always earns exactly the 1.0x floor.
    await expect(topRow).toContainText("1.0x");
  });

  // Weeks 4-6 holds six bye teams (two games, not three). They rank on points
  // PER GAME and price on the bye line — the usual curve x1.5 — and the
  // page's JS mirror must reproduce the server's two-line prices, or a drag or
  // "Save Multipliers" would knock every bye team back onto the 3-game line.
  test("a bye span prices bye teams on the two-game line, in Ruby and JS alike", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/slates/nfl-2026-weeks-4-6");

    await expect(page.getByTestId("two-line-note")).toContainText("per game");
    const byeRows = page.locator("div.sortable-item[data-game-factor='1.5']");
    await expect(byeRows).toHaveCount(6);
    await expect(page.getByTestId("bye-line-badge")).toHaveCount(6);

    const prices = async () =>
      page.locator("div.sortable-item").evaluateAll((rows) =>
        rows.map((row) => [row.dataset.matchupId, row.querySelector(".turf-score-display").textContent.trim()])
      );
    const serverPrices = await prices();

    // Every bye price sits on the x1.5-x3.0 line.
    for (const text of await byeRows.locator(".turf-score-display").allTextContents()) {
      const mult = parseFloat(text);
      expect(mult).toBeGreaterThanOrEqual(1.5);
      expect(mult).toBeLessThanOrEqual(3.0);
    }

    // Blank every displayed price, so whatever reads back after the re-sort
    // can ONLY have come from the JS mirror's recompute — not the server render.
    await page.locator(".turf-score-display").evaluateAll((els) => els.forEach((el) => (el.textContent = "?")));

    // Sorting by DK per game reproduces the server's order, so the JS prices
    // must equal the server's, row for row. The wait is on the blanks being
    // gone, which the pre-click page cannot satisfy.
    await page.getByRole("button", { name: "Sort by DK Score" }).first().click();
    await expect(page.locator(".turf-score-display", { hasText: "?" })).toHaveCount(0);
    expect(await prices()).toEqual(serverPrices);
  });

  // The slider used to drive a JavaScript copy of the pricing curve, and the two
  // implementations rounded an exact tie differently — while "Save Multipliers"
  // posts what is on screen. The page now looks prices up from a Ruby-built
  // table, so this asserts the display IS that table at a non-default scale.
  test("dragging the scale shows Ruby's prices, not a recomputed curve", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/slates/nfl-2026-weeks-1-3");

    // Move the multiplier scale off its default and let the page redraw.
    const slider = page.locator('input[type=range][x-model\\.number="multScale"]');
    await slider.fill("4.5");
    await slider.dispatchEvent("input");
    await expect(page.locator(".turf-score-display").first()).not.toHaveText("—x");

    const shown = await page.locator("div.sortable-item").evaluateAll((rows) =>
      rows.map((row) => ({
        factor: (parseFloat(row.dataset.gameFactor) || 1).toFixed(1),
        text: row.querySelector(".turf-score-display").textContent.trim()
      }))
    );
    const table = await page.evaluate(() => window._fcPrices || _fcPrices);

    expect(shown.length).toBe(32);
    shown.forEach((row, index) => {
      const expected = table["4.5"][row.factor][index];
      expect(row.text).toBe(expected.toFixed(1) + "x");
    });
  });

  test("a single-week slate still renders one row per team", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/slates/nfl-2026-week-1");

    // Same 32 teams, but one game each — the regression that matters is that
    // nothing about the one-week page changed.
    await expect(page.locator("div.sortable-item")).toHaveCount(32);

    const topRow = page.locator("div.sortable-item").first();
    const dk = parseFloat((await topRow.innerText()).match(/DK\s+([0-9.]+)/)[1]);
    expect(dk).toBeLessThan(50);
  });
});
