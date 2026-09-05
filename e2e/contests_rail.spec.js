const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed, seedRailContests, clearRailContests } = require("./helpers");

// THE /contests FEATURED RAIL — the two properties no server-side tier can see.
//
// Both are about the BROWSER, which is why they are here and not in
// test/integration/contests_page_bands_test.rb:
//
//   1. The right-edge fade is a MEASUREMENT, not a style. Whether the rail has
//      more to show is `scrollWidth > clientWidth + scrollLeft`, and no
//      rendered-HTML assertion can settle it. The falsifiable half is the one
//      worth having: at the END of the scroll there is nothing more to the
//      right, and a fade still painted there is a lie about what is off-screen.
//      Asserted by reading the COMPUTED mask, not the style attribute — an
//      inline style that fails to apply reads as present in the attribute.
//
//   2. The Coming Soon flag goes in through the REAL admin control and comes
//      out the other end as a dimmed, sashed, re-sorted card. The integration
//      tier proves the card renders that way given the column; only this proves
//      the button on /contests/:slug/edit actually writes the column.
//
// The specs seed their own contests because the dev seed ships exactly one, and
// neither an overflowing rail nor an ordering can be observed with one card.
// Both clear up after themselves: the lane runs one worker against one
// database, so a leftover contest is paid for by every later spec that measures
// this page.
test.beforeEach(async ({ request }) => await reseed(request));

test.describe("Contests featured rail", () => {
  test.afterEach(async ({ page }) => await clearRailContests(page));

  test("the right-edge fade clears once the rail is scrolled to its end", async ({ page }) => {
    await seedRailContests(page, 8);
    await page.goto("/contests");

    const rail = page.locator("[data-contest-rail]");
    await expect(rail).toBeVisible();

    // The premise, stated rather than assumed: eight cards must not fit, or
    // there is no fade to test and this spec passes vacuously.
    const overflows = await rail.evaluate((el) => el.scrollWidth > el.clientWidth);
    expect(overflows, "the rail must overflow or this spec proves nothing").toBeTruthy();

    await expect
      .poll(async () => rail.evaluate((el) => getComputedStyle(el).maskImage))
      .not.toBe("none");

    // Every card title on ONE line, swept across the whole rail rather than
    // sampled. The fixture includes one deliberately long operator-typed name,
    // so this cannot go vacuous — without the single-line rule that card's
    // title wraps and measures two line-boxes tall.
    const titleLines = await page.locator("[data-contest-card] h2").evaluateAll((els) =>
      els.map((el) => Math.round(el.getBoundingClientRect().height / parseFloat(getComputedStyle(el).lineHeight)))
    );
    expect(titleLines.length, "the rail must have cards to measure").toBeGreaterThan(0);
    expect(titleLines, "a contest name may never wrap onto a second line").toEqual(titleLines.map(() => 1));

    await rail.evaluate((el) => { el.scrollLeft = el.scrollWidth; });

    // Nothing is off-screen any more, so nothing may be faded away.
    await expect
      .poll(async () => rail.evaluate((el) => getComputedStyle(el).maskImage))
      .toBe("none");
  });

  test("an admin flips Coming Soon and the card dims, sashes and sorts to the back", async ({ page }) => {
    const { slugs } = await seedRailContests(page, 3);
    const [newest, second] = slugs;   // seeded newest-first, so `newest` leads the rail
    await loginAdmin(page);

    const card = (slug) => page.locator(`[data-contest-card='${slug}']`);
    const positionOf = async (slug) =>
      card(slug).evaluate((el) => el.getBoundingClientRect().left + el.ownerDocument.defaultView.scrollX +
        el.closest("[data-contest-rail]").scrollLeft);

    await page.goto("/contests");
    await expect(card(newest).locator("[data-contest-sash]")).toHaveCount(0);
    const before = await positionOf(newest);
    expect(before, "the newest open contest leads the rail").toBeLessThan(await positionOf(second));

    // Through the real control on the real form.
    await page.goto(`/contests/${newest}/edit`);
    await page.getByRole("button", { name: "Coming Soon: Off" }).click();
    await page.getByRole("button", { name: "Save Changes" }).click();
    await page.waitForURL((url) => !url.pathname.endsWith("/edit"));

    await page.goto("/contests");
    await expect(card(newest).locator("[data-contest-sash=soon]")).toHaveText("Coming Soon");
    await expect(card(newest).locator("[data-contest-dim]")).toHaveCount(1);
    expect(
      await positionOf(newest),
      "a coming-soon contest sits behind every open one however new it is"
    ).toBeGreaterThan(await positionOf(second));

    // And back off again — the toggle is not one-way, and this leaves the
    // fixture as it was found for the teardown.
    await page.goto(`/contests/${newest}/edit`);
    await page.getByRole("button", { name: "Coming Soon: On" }).click();
    await page.getByRole("button", { name: "Save Changes" }).click();
    await page.waitForURL((url) => !url.pathname.endsWith("/edit"));

    await page.goto("/contests");
    await expect(card(newest).locator("[data-contest-sash]")).toHaveCount(0);
    await expect(card(newest).locator("[data-contest-dim]")).toHaveCount(0);
  });
});
