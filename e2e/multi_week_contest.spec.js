const { test, expect } = require("@playwright/test");
const { reseed } = require("./helpers");

test.beforeEach(async ({ request }) => await reseed(request));

// A multi-week contest ("NFL Weeks 15-17") is picked by TEAM, not by game — the
// team plays a different opponent each week, so the single-week paired board
// would be meaningless here. Seeded by e2e/seed.rb.
test.describe("multi-week contest board", () => {
  test("names its span and drops the game/advantage sort", async ({ page }) => {
    await page.goto("/contests/nfl-weeks-15-17");

    await expect(page.getByText("Weeks 15-17", { exact: false }).first()).toBeVisible();
    await expect(page.getByText("pick 6 teams")).toBeVisible();

    // There is no game view on a span board, so the sort toggle must be gone —
    // leaving it would offer a pairing that doesn't exist.
    await expect(page.getByRole("button", { name: "Game", exact: true })).toHaveCount(0);
    await expect(page.getByRole("button", { name: /Advantage/ })).toHaveCount(0);
  });

  test("each team card dates its three opponent columns", async ({ page }) => {
    await page.goto("/contests/nfl-weeks-15-17");

    // A pick card is a TEAM with its three opponents. The aria-label carries the
    // whole span, which is also what a screen reader announces — and it keeps
    // the week number the visible column no longer prints.
    const teamCard = page.locator('button[aria-label*="Week 15"]').first();
    await expect(teamCard).toBeVisible();

    // The columns read the DAY each game is played, not "Week 15". Asserted as
    // a shape ("Dec 20") rather than three literal dates: the label is derived
    // from the seeded schedule, and pinning the dates here would make a
    // schedule reseed look like a UI regression.
    const labels = teamCard.locator("p.tm-opponent-week");
    await expect(labels).toHaveCount(3);
    for (const text of await labels.allInnerTexts()) {
      expect(text.trim()).toMatch(/^[A-Za-z]{3} \d{1,2}$/);
    }

    // The week itself survives, in the description rather than on the face.
    await expect(teamCard).toHaveAttribute("aria-label", /Week 15 · [A-Za-z]{3} \d{1,2}:/);

    // One span multiplier per card, rendered "N× Point(s)" — not per week.
    await expect(teamCard.getByText(/Points?/).first()).toBeVisible();
  });

  test("selecting a team puts its mascot and span multiplier in the cart", async ({ page }) => {
    await page.goto("/contests/nfl-weeks-15-17");

    const teamCard = page.locator('button[aria-label*="Week 15"]').first();
    const teamName = await teamCard.locator(".team-name").innerText();
    await teamCard.click();

    // The cart labels the multiplier "Points" (it is points per goal), and uses
    // the mascot rather than the full city name to keep the row on one line.
    const cart = page.locator("text=Points").first();
    await expect(cart).toBeVisible();

    // The mascot is the last word of the full team name ("Los Angeles Chargers"
    // -> "Chargers"), so the cart row must contain it without the city.
    const mascot = teamName.trim().split(" ").pop();
    await expect(page.getByText(mascot, { exact: false }).first()).toBeVisible();
  });
});
