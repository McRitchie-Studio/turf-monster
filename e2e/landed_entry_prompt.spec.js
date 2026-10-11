const { test, expect } = require("@playwright/test");
const { login, reseed } = require("./helpers");

// The landed-entry prompt (Entry::LandedHold) as the player sees it: a paid
// entry an app gate refused is asked about on the next signed-in page. The
// integration tier proves the HTML; only a browser proves the card is VISIBLE
// below the fixed navbar and that its plain form answers at once, with no wait
// on any script.
//
// The row is written by TestController#set_landed_entry (rows only, no chain).
// "Decline" is the answer pressed here because it reads no chain; re-authorize
// runs the verdict, which the integration tier drives against LedgerVault.
const PLAYER = "mason@mcritchie.studio";

test.describe("Landed entry prompt", () => {
  test.beforeEach(async ({ request }) => await reseed(request));

  test.afterEach(async ({ page }) => {
    await page.request.post("/test/set_landed_entry", { data: { clear: "true" } });
  });

  test("a held paid entry is asked about on the next page, and decline answers at once", async ({ page }) => {
    await login(page, PLAYER);

    // Control: with nothing held there is no card.
    await page.goto("/contests");
    await expect(page.locator("[data-landed-entry-prompt]")).toHaveCount(0);

    const res = await page.request.post("/test/set_landed_entry");
    expect(res.ok()).toBeTruthy();
    const { slug, contest } = await res.json();

    await page.goto("/contests");
    const card = page.locator(`[data-landed-entry-prompt='${slug}']`);
    await expect(card).toBeVisible();
    await expect(card).toContainText("Your payment arrived. Do you still want this entry?");
    await expect(card).toContainText(contest);
    await expect(card).toContainText("You will not be charged again");
    await expect(card.locator("[data-landed-entry-deadline]")).toHaveText(/^Sun, [A-Z][a-z]{2} \d{1,2} at 9:00 AM ET$/);
    await expect(card.getByRole("button", { name: "Yes, keep my entry" })).toBeEnabled();

    // The card sits in the page, not under the fixed navbar: a hit test at
    // its heading answers from inside it.
    const heading = card.locator("h2");
    const box = await heading.boundingBox();
    const hit = await page.evaluate(
      ([x, y]) => document.elementFromPoint(x, y)?.closest("[data-landed-entry-prompt]")?.dataset.landedEntryPrompt,
      [box.x + box.width / 2, box.y + box.height / 2]
    );
    expect(hit).toBe(slug);

    // Pressed the moment the page is there, with no wait on a controller.
    await page.goto("/contests");
    await card.getByRole("button", { name: "No, I don't want it" }).click();
    await expect(page.getByText("This entry stays out, and you will not be charged again.")).toBeVisible();
    await expect(page.locator("[data-landed-entry-prompt]")).toHaveCount(0);

    await page.goto("/account");
    await expect(page.locator("[data-landed-entry-prompt]")).toHaveCount(0);
  });
});
