const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] The Signatures badge in the admin menu.
//
// WHY A BROWSER. The badge's signal is its WEIGHT — gray at zero, bold when
// something is waiting — so an operator can catch it peripherally without
// reading the digit. A rendered-markup test can only confirm the class name is
// in the attribute; it cannot tell you the class produced any weight at all.
// Tailwind compiles the utilities it can SEE, and a class that never makes it
// into the build emits no rule while every String assertion keeps passing. The
// computed font-weight is the only witness that the distinction actually
// reaches a reader's eye.
//
// Both branches are exercised on purpose. The bold one is the one that matters,
// and the seeded database has nothing pending — so the spec states its premise
// through /test/set_pending_signatures rather than hoping for one.
test.beforeEach(async ({ request }) => await reseed(request));

// AND PUT THEM BACK. `reseed` does not delete PendingTransactions, and the lane
// runs one server with one worker, so rows seeded here outlive this file. That
// has been harmless only because "signatures_nav_badge" sorts after every spec
// that cares — e2e/audit.spec.js:126 asserts the treasury's EMPTY state. A new
// spec file with an earlier name inherits the landmine; one did
// (admin_desktop_only.spec.js, 2026-09-08) and reddened CI on a change that had
// nothing to do with this file.
test.afterEach(async ({ request }) => await setSignatures(request, 0, 0));

const setSignatures = (request, live, stale) =>
  request.post("/test/set_pending_signatures", { form: { live, stale } });

async function openAdminMenu(page) {
  await page.locator('button[aria-label="Toggle admin menu"]').first().click();
  await page.locator("[data-signature-count]").first().waitFor({ state: "visible" });
}

const badge = (page) => page.locator("[data-signature-count]").first();

test.describe("Signatures badge", () => {
  test("bold when signatures are waiting, and counts only live ones @smoke", async ({ page, request }) => {
    // Two waiting, three stale. A badge wired to `pending` would read five —
    // which is the production shape this flag exists to stop (11 pending, 1 real).
    await setSignatures(request, 2, 3);
    await loginAdmin(page);
    await page.goto("/contests");
    await openAdminMenu(page);

    await expect(badge(page)).toHaveAttribute("data-signature-count", "2");
    await expect(badge(page)).toHaveText("2");

    const weight = await badge(page).evaluate((el) => getComputedStyle(el).fontWeight);
    expect(Number(weight)).toBeGreaterThanOrEqual(700);
  });

  test("gray and unbolded when nothing is waiting @smoke", async ({ page, request }) => {
    // Only stale rows: still `pending` in the database, still not your problem.
    await setSignatures(request, 0, 4);
    await loginAdmin(page);
    await page.goto("/contests");
    await openAdminMenu(page);

    await expect(badge(page)).toHaveAttribute("data-signature-count", "0");

    const style = await badge(page).evaluate((el) => {
      const s = getComputedStyle(el);
      return { weight: Number(s.fontWeight), color: s.color };
    });
    expect(style.weight).toBeLessThan(700);
    // Muted, not the body colour — the row should recede when there is nothing
    // to do. Asserted as "different from the label beside it" so a palette
    // change doesn't make this brittle.
    const labelColor = await page
      .locator("[data-signature-count]")
      .first()
      .evaluate((el) => getComputedStyle(el.previousElementSibling).color);
    expect(style.color).not.toBe(labelColor);
  });

  test("the row links to the treasury queue @smoke", async ({ page, request }) => {
    await setSignatures(request, 1, 0);
    await loginAdmin(page);
    await page.goto("/contests");
    await openAdminMenu(page);

    await badge(page).click();
    await page.waitForURL(/\/admin\/pending_transactions/);
    await expect(page.locator("h1, h2").filter({ hasText: /Treasury/i }).first()).toBeVisible();
  });
});
