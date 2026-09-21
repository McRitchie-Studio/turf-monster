const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

test.beforeEach(async ({ request }) => await reseed(request));

// Write the Admin Formula's multiplier scale through the REAL form — the same
// path an admin uses, and the same one the off-grid spec below exercises.
//
// A BLANK value clears the column: `params.permit` passes "" straight through
// and ActiveRecord casts it to nil on the float column, which is the seeded
// state (db/seeds.rb creates "Default" with no formula attributes at all).
// Do NOT "restore" by typing back what the form displays — the field renders
// `resolved[:formula_mult_scale]`, which is the 2.0 FALLBACK, not the stored
// value. Saving that would leave every NFL slate resolving at 2.0 instead of
// the sport-aware 1.0 it gets when nothing stores a scale: the same pollution,
// one step quieter.
async function saveDefaultMultScale(page, value) {
  await page.goto("/slates/admin_formula");
  await page.locator('input[name="formula_mult_scale"]').fill(value);
  await page.locator('form button[type=submit], form input[type=submit]').first().click();
  await page.waitForLoadState("networkidle");
}

// The scale the board is actually keyed on, read from the page's own seed
// (`_fcSliders.multScale` = `price_key(@slate.resolved_formula[...])`). This is
// the observable the Default slate's stored scale moves.
async function boardMultScale(page, slug) {
  await page.goto(`/slates/${slug}`);
  return page.evaluate(() => (window._fcSliders || _fcSliders).multScale);
}

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

  // THE WHOLE CHAIN, WHICH ONLY A BROWSER WALKS. The board seeds its scale from
  // the saved formula, not from the slider, and the Admin Formula field steps by
  // 0.1 — so an admin can save a scale no slider position equals. The price
  // table is keyed by string, the lookup misses, every row reads "—x", and a
  // drag then saves each team's OLD price against its NEW rank.
  //
  // Neither half is visible below a browser: the helper test proves the table
  // HAS a "2.3" row, and the controller test proves the page SHIPS one, but only
  // here does an admin actually save 2.3 on one page and read prices on another.
  test("a scale saved off the slider's grid still prices every row", async ({ page }) => {
    await loginAdmin(page);

    try {
      // The real path: type it into the admin formula field and save.
      await saveDefaultMultScale(page, "2.3");

      await page.goto("/slates/nfl-2026-weeks-1-3");

      await expect(page.locator("div.sortable-item")).toHaveCount(32);

      // The page seeds the SAVED scale, not a slider position — this is the value
      // the lookup is about to be keyed on.
      expect(await page.evaluate(() => (window._fcSliders || _fcSliders).multScale)).toBe(2.3);

      // Assert against the page's OWN lookup rather than the rendered text: until
      // the slider is touched the board shows each matchup's STORED turf_score,
      // so the text proves nothing about the table. `_fcMult` is what a drag
      // calls, and what "Save Multipliers" then persists.
      const priced = await page.evaluate(() => {
        const rows = Array.from(document.querySelectorAll("div.sortable-item"));
        return rows.map((row, index) =>
          _fcMult(index + 1, rows.length, _fcSliders.multScale, parseFloat(row.dataset.gameFactor) || 1.0)
        );
      });

      // Before the fix every one of these was null: no "2.3" row existed, so the
      // board would have saved each team's old price against its new rank.
      expect(priced).toHaveLength(32);
      expect(priced.filter((price) => price === null || price === undefined)).toEqual([]);

      // And every one is the number Ruby computed for 2.3.
      const table = await page.evaluate(() => window._fcPrices || _fcPrices);
      expect(Object.keys(table)).toContain("2.3");
      priced.forEach((price, index) => {
        expect(price).toBe(table["2.3"]["1.0"][index]);
      });
    } finally {
      // PUT THE GLOBAL DEFAULT SLATE BACK. 2.3 is saved on the ONE "Default"
      // row every other slate falls back through (Slate#resolved_formula), and
      // `reseed` does not touch that record — so without this, every slate spec
      // ordered after this file inherits a scale nobody set. It is not confined
      // to the Default row either: with 2.3 stored there, an NFL slate that
      // stores no scale of its own resolves 2.3 instead of 1.0, because the
      // sport-aware fallback only fires while BOTH are unset.
      //
      // In `finally`, so a failed assertion above still hands the next spec a
      // clean board. The restore is ASSERTED by the test that follows, not
      // here — an expect() in this block would mask the real failure.
      await saveDefaultMultScale(page, "");
    }
  });

  // THE PROOF THAT THE RESTORE ABOVE ACTUALLY RAN — ordered immediately after
  // it, reading the same observable the save moved.
  //
  // 1.0 is the seeded answer for an NFL board: neither the slate nor the
  // "Default" row stores a `formula_mult_scale`, so `Slate#resolved_formula`
  // takes its sport-aware branch (NFL tops out at x2.0 on a base of 1.0) rather
  // than FORMULA_DEFAULTS' fifa value of 2.0. Reading 2.3 here means the spec
  // above leaked; reading 2.0 would mean someone "restored" it by typing back
  // the number the admin form displays, which is the resolved fallback and not
  // the stored value.
  //
  // `reseed` in beforeEach cannot cover for this — it clears caches, throttles,
  // OmniAuth mocks, users and entries, and touches no Slate row. So this test
  // is only green because the spec above cleaned up after itself.
  test("the off-grid scale is handed back, not left on the Default slate", async ({ page }) => {
    await loginAdmin(page);

    expect(await boardMultScale(page, "nfl-2026-weeks-1-3")).toBe(1.0);
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
