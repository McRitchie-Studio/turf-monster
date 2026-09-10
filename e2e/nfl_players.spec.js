const { test, expect } = require("@playwright/test");

// The NFL player database browse surface.
//
// WHAT THIS LANE CAN SEE: the e2e database is built by `db:seed`, which loads
// db/seeds/nfl_athletes_demo.rb — a fixed, OFFLINE set of 16 real players
// across 8 teams. The full ~2,900-player league arrives from
// `bin/rails nfl:players_seed`, which downloads a 7MB CSV and writes to S3;
// neither belongs in a test lane. So every assertion here is pinned to the
// demo set, never to a league-wide count that a re-seed could move.
//
// WHAT IT DELIBERATELY DOES NOT COVER: the cached-headshot <img> path. The demo
// seed caches no images (that needs AWS), so these players all render the
// initials fallback. The <img> branch is covered against a fixture in
// test/views/nfl_player_card_render_test.rb.
test.describe("NFL players", () => {
  // The whole surface is public — it is a marketing/SEO page, and a
  // require_authentication that crept back in would fail here first.
  test("the index is reachable signed-out and lists every team", async ({ page }) => {
    await page.goto("/nfl-players");

    await expect(page.getByRole("heading", { name: "NFL Players" })).toBeVisible();

    // 32 franchises, each a link into its own roster. Asserting the count
    // rather than one team pins that the picker renders the league, not a slice.
    const teamLinks = page.locator('a[href^="/nfl-players?team="]');
    await expect(teamLinks).toHaveCount(32);

    // The default view must NOT render player cards — that is the guard that
    // keeps a 2,900-row page from ever shipping.
    await expect(page.locator("[data-athlete-card]")).toHaveCount(0);
  });

  test("choosing a team shows that team's roster", async ({ page }) => {
    await page.goto("/nfl-players");
    await page.locator('a[href="/nfl-players?team=buffalo-bills"]').click();

    await expect(page).toHaveURL(/team=buffalo-bills/);
    await expect(page.getByRole("heading", { name: /Bills Roster/ })).toBeVisible();

    // Three Bills in the demo set: Allen (QB), Cook (RB), Shakir (WR).
    const cards = page.locator("[data-athlete-card]");
    await expect(cards).toHaveCount(3);
    await expect(cards.first()).toContainText("Josh Allen");

    // Position order, not alphabetical: QB leads, and Allen sorts after both
    // Cook and Shakir by last name.
    await expect(cards.first()).toHaveAttribute("data-position", "QB");
  });

  test("the search box narrows the rendered roster", async ({ page }) => {
    await page.goto("/nfl-players?team=buffalo-bills");

    const cards = page.locator("[data-athlete-card]");
    await expect(cards).toHaveCount(3);

    await page.getByPlaceholder("Search players...").fill("shakir");

    // cardListFilter hides by display:none, so the nodes stay in the DOM —
    // assert on VISIBILITY, and wait for the count readout the component owns
    // rather than racing its 300ms debounce.
    await expect(page.locator("[data-athlete-card]:visible")).toHaveCount(1);
    await expect(page.locator("[data-athlete-card]:visible")).toContainText("Khalil Shakir");
  });

  test("the position filter spans teams", async ({ page }) => {
    await page.goto("/nfl-players?position=QB");

    // Allen, Mahomes, Hurts — three teams, one position.
    const cards = page.locator("[data-athlete-card]");
    await expect(cards).toHaveCount(3);
    for (const pos of await cards.evaluateAll((els) =>
      els.map((e) => e.dataset.position),
    )) {
      expect(pos).toBe("QB");
    }
  });

  test("a player card opens that player's page", async ({ page }) => {
    await page.goto("/nfl-players?team=buffalo-bills");
    await page.locator("[data-athlete-card]").first().click();

    await expect(page).toHaveURL("/nfl-players/josh-allen");
    await expect(page.getByRole("heading", { name: "Josh Allen", level: 1 })).toBeVisible();

    // The bio block is the reason the detail page exists.
    await expect(page.getByText("Wyoming")).toBeVisible();
    await expect(page.getByText("237 lbs")).toBeVisible();

    // Teammates, and never the player themselves. Collect the text rather than
    // asserting `.not.toContainText` on the locator — that matcher runs in
    // strict mode and throws on a multi-element locator instead of failing the
    // way it reads.
    const teammates = page.locator("[data-athlete-card]");
    await expect(teammates).toHaveCount(2);

    const names = (await teammates.allTextContents()).join(" ");
    expect(names).toContain("James Cook");
    expect(names).toContain("Khalil Shakir");
    expect(names).not.toContain("Josh Allen");
  });

  // Two active players are named Justin Jefferson — a Vikings receiver and a
  // Browns linebacker. Before the importer told them apart, the second
  // overwrote the first and the receiver disappeared. Both are in the demo set
  // so the regression is visible from the outside, not only in a unit test.
  test("two players who share a name both have their own page", async ({ page }) => {
    await page.goto("/nfl-players?team=minnesota-vikings");
    await expect(page.locator("[data-athlete-card]")).toContainText("Justin Jefferson");
    await expect(page.locator("[data-athlete-card]").first()).toHaveAttribute("data-position", "WR");

    await page.goto("/nfl-players?team=cleveland-browns");
    await expect(page.locator("[data-athlete-card]")).toContainText("Justin Jefferson");
    await expect(page.locator("[data-athlete-card]").first()).toHaveAttribute("data-position", "LB");
  });

  test("an unknown player redirects instead of erroring", async ({ page }) => {
    await page.goto("/nfl-players/nobody-at-all");
    await expect(page).toHaveURL("/nfl-players");
  });
});
