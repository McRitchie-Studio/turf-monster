const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// The birthday → age-gate refusal handoff (adopt-birthday-age-gate-flow).
//
// WHY THIS NEEDS A BROWSER, and what the other tiers genuinely cannot see.
// The controller test proves /age/verify answers `underage: true`. The component
// test proves the card is mounted with `gateId: 'age-gate'`. Neither can prove
// the two meet: the routing lives in the engine's fetch callback, which reads
// the response and decides between swapping cards and painting a red line. Both
// tiers stay green if that callback is wrong, or if the gate id is registered on
// a layout the card is never opened from.
//
// It also pins the behaviour this whole change exists to remove. The deleted
// modals/_age_verify refused an under-age date CLIENT-SIDE, turning the card red
// and disabling its own submit — the one screen state with nothing to press. The
// negative assertion in the first spec is what keeps that from coming back: a
// resurrected client-side refusal would leave the person on the birthday card,
// and every server-side assertion would still pass.
test.setTimeout(90_000);

test.beforeEach(async ({ request }) => await reseed(request));

// A date that is comfortably under every jurisdiction's bar in AgePolicy.
const UNDERAGE_YEAR = new Date().getFullYear() - 16;

async function openBirthdayCard(page) {
  await loginAdmin(page);
  await page.goto("/");
  await page.evaluate(() => window.Alpine.store("modals").open("birthday", {}));
  // Scope to the HEADING. Playwright's text= is a case-insensitive SUBSTRING
  // match, so "Your birthday" also matches the gate card's "Update your
  // Birthday" back link — which made the negative assertion below fail against a
  // page that was behaving correctly.
  await expect(page.locator('h3:text-is("Your birthday")')).toBeVisible();
}

async function fillUnderageDob(page) {
  await page.selectOption('select[x-model="month"]', "1");
  await page.selectOption('select[x-model="day"]', "1");
  await page.selectOption('select[x-model="year"]', String(UNDERAGE_YEAR));
}

async function submitUnderageDob(page) {
  await fillUnderageDob(page);
  await page.locator('button:has-text("Confirm & Continue")').click();
}

test.describe("Birthday → age gate", () => {
  test("an under-age date submits and lands on the refusal card", async ({ page }) => {
    await openBirthdayCard(page);

    // The submit must be LIVE once an under-age date is COMPLETE. Assert it after
    // filling, not before: the engine disables the button on `!complete ||
    // submitting`, so an empty card is legitimately disabled and checking there
    // proves nothing about age — it just re-reads the completeness rule. The
    // deleted fork disabled this button for the age itself, which is the dead
    // end this whole change removes.
    const submit = page.locator('button:has-text("Confirm & Continue")');
    await fillUnderageDob(page);
    await expect(submit).toBeEnabled();

    await submit.click();

    // The refusal is its own card with somewhere to go — not red text on the
    // card the person is already stuck on.
    await expect(page.locator('button:has-text("Watch the Contest"), a:has-text("Watch the Contest")'))
      .toBeVisible();
    // The DOB selects are the card's substance and are unambiguous — the gate
    // card carries none. Asserting the heading alone would be enough now, but
    // the selects say "the ask is gone", which is the claim.
    await expect(page.locator('h3:text-is("Your birthday")')).toBeHidden();
    await expect(page.locator('select[x-model="month"]')).toBeHidden();
  });

  test("the refusal card offers a real contest to watch", async ({ page }) => {
    await openBirthdayCard(page);
    await submitUnderageDob(page);

    // The engine DROPS this CTA when watch_url is absent rather than rendering a
    // dead button, so a missing link is invisible on screen — the card just
    // quietly loses the one thing it exists to offer. Assert the destination,
    // not the button.
    const watch = page.locator('a:has-text("Watch the Contest")').first();
    await expect(watch).toBeVisible();
    const href = await watch.getAttribute("href");
    expect(href, "the watch CTA must carry a real destination").toBeTruthy();
    expect(href).not.toBe("#");
    expect(href).toMatch(/^\/contests(\/|$)/);
  });

  test("the back link returns to the birthday card so a typo is fixable", async ({ page }) => {
    await openBirthdayCard(page);
    await submitUnderageDob(page);

    // A mis-picked year is one scroll away from a correct one. A gate with no
    // way back turns an ordinary typo into a locked door.
    await page.locator('button:has-text("Update your Birthday"), a:has-text("Update your Birthday")')
      .first()
      .click();

    await expect(page.locator('h3:text-is("Your birthday")')).toBeVisible();
    // ...and editable, not a read-only echo of the rejected date.
    await expect(page.locator('select[x-model="year"]')).toBeEnabled();
  });
});
