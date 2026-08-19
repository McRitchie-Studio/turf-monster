const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// The "Your Picks" sidebar after a BACK navigation.
//
// Operator report (2026-08-18): with 6 of 6 picks made, opening the
// wallet-setup modal's "Read the setup guide" link and then hitting Back left
// the sidebar showing TWELVE rows — the six real picks plus six blank ones.
//
// The mechanism is Turbo's page cache meeting Alpine's `x-for`. Turbo snapshots
// the live DOM, which by then contains the elements `x-for` GENERATED, and a
// restoration visit puts that snapshot back. Alpine then initialises the
// restored tree from scratch: its `x-for` has no memory of the nodes in the
// snapshot, so it renders a fresh set beside them. The cached ones survive as
// orphans — no scope, so their `x-text` bindings resolve to nothing, which is
// why the operator saw blank rows rather than doubled picks.
//
// This can only be proven in a browser: it needs a real Turbo cache, a real
// restoration visit, and a real Alpine re-init. No server-rendered tier sees it
// at all — the HTML the server sends is correct both times.
test.setTimeout(60_000);

test.beforeEach(async ({ request }) => await reseed(request));

const CONTEST = "/contests/world-cup-2026";
// Every direct child of the sidebar's scroll container is one pick slot: the
// `x-for` template's root element. Counting these (rather than a data hook the
// fix could add) is what makes this a regression test — it counts what the
// BROWSER ended up with, and it fails against the unfixed partial.
const SLOTS = "#entry-sidebar div.overflow-y-auto > div";

async function makeSixPicks(page) {
  await page.goto(CONTEST);
  await page.waitForLoadState("networkidle");

  // Start from a known-empty cart: a prior spec's session may have left picks.
  await page.evaluate(async (contest) => {
    const csrfToken = document.querySelector('meta[name="csrf-token"]')?.content;
    await fetch(`${contest}/clear_picks`, {
      method: "POST",
      headers: { "X-CSRF-Token": csrfToken, Accept: "application/json" },
    });
  }, CONTEST);
  await page.reload();
  await page.waitForLoadState("networkidle");

  const cards = page.locator(
    '[x-data*="selectionBoard"] button[role="checkbox"]:not([disabled])'
  );
  for (let i = 0; i < 6; i++) {
    // The board dims behind the cart on the first pick; the overlay swallows
    // the next click if we don't dismiss it (same dance as geo_hold_validation).
    const blurOverlay = page.locator("div.fixed.inset-0.z-20.cursor-pointer");
    if (await blurOverlay.isVisible({ timeout: 300 }).catch(() => false)) {
      await blurOverlay.click();
    }
    await cards.nth(i).click();
    await expect(page.locator("body")).toContainText(`${i + 1} / 6`);
  }
}

test("the picks sidebar keeps exactly six slots after a Turbo back-navigation", async ({
  page,
}) => {
  await loginAdmin(page);
  await makeSixPicks(page);

  // Reload so the SERVER-RENDERED page carries the picks. This is what the
  // operator's session had (they signed in through a magic link after picking,
  // which re-rendered the board from the persisted cart), and it is what makes
  // the snapshot Turbo caches a full one. Without it the cached HTML predates
  // the picks, the restored board comes back empty, and the duplicate rows are
  // blank-on-blank — the bug still reproduces, but not as it was reported.
  await page.reload();
  await page.waitForLoadState("networkidle");
  await expect(page.locator("body")).toContainText("6 / 6");

  await expect(page.locator(SLOTS)).toHaveCount(6);

  // A real in-page Turbo visit, then a real restoration visit back to it.
  // page.goto() would be a full browser load and would NOT exercise the
  // snapshot cache, so it would pass against the broken partial.
  // (The navbar's "Rules" link lands on /turf-totals-v1, not /rules — wait on
  // "left the contest" rather than on a path this spec would have to keep in
  // sync with the marketing route.)
  await page.getByRole("link", { name: "Rules" }).first().click();
  await page.waitForURL((u) => !u.pathname.startsWith("/contests"));
  await page.goBack();
  await page.waitForURL((u) => u.pathname.startsWith("/contests"));

  await expect(page.locator(SLOTS)).toHaveCount(6);
  // The six that survive must be the REAL picks, not six empty shells: a fix
  // that cleared the wrong set would still count six.
  await expect(page.locator("body")).toContainText("6 / 6");
});
