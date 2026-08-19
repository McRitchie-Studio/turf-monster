const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// The cart must come BACK with the picks you actually made.
//
// #board-config carries cartSelections, rendered server-side from the persisted
// cart entry, and selectionBoard() re-reads it on every init. Client picks never
// rewrote it, so a Turbo restoration visit replayed the cart as of the last
// SERVER RENDER — every pick made since page load silently gone.
//
// The boundary that makes this testable: only picks made since the last server
// render were lost. e2e/pick_slots_turbo_restore.spec.js works around it to this
// day with a deliberate page.reload() after picking, which re-renders the blob
// WITH the picks. This spec is the same journey with that reload DELETED — the
// one difference that separates a fixed build from a broken one.
test.setTimeout(60_000);

test.beforeEach(async ({ request }) => await reseed(request));

const CONTEST = "/contests/world-cup-2026";
const SLOTS = "#entry-sidebar div.overflow-y-auto > div";

async function pickSix(page) {
  await page.goto(CONTEST);
  await page.waitForLoadState("networkidle");

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
    const blurOverlay = page.locator("div.fixed.inset-0.z-20.cursor-pointer");
    if (await blurOverlay.isVisible({ timeout: 300 }).catch(() => false)) {
      await blurOverlay.click();
    }
    await cards.nth(i).click();
    await expect(page.locator("body")).toContainText(`${i + 1} / 6`);
  }
}

async function leaveAndComeBack(page) {
  // A real Turbo visit and a real restoration visit. page.goto() is a full
  // browser load that never touches the snapshot cache, so it would pass
  // against the broken build.
  await page.getByRole("link", { name: "Rules" }).first().click();
  await page.waitForURL((u) => !u.pathname.startsWith("/contests"));
  await page.goBack();
  await page.waitForURL((u) => u.pathname.startsWith("/contests"));
}

test("a signed-in cart survives a Turbo back-navigation with NO reload first", async ({
  page,
}) => {
  await loginAdmin(page);
  await pickSix(page);

  await leaveAndComeBack(page);

  // The count alone is not the claim — six EMPTY slots would also count six.
  await expect(page.locator("body")).toContainText("6 / 6");
  await expect(page.locator(SLOTS)).toHaveCount(6);
  await expect(page.locator(`${SLOTS} >> text=Pick 1`)).toHaveCount(0);
});

test("the restored cart carries the picks themselves, not just the count", async ({
  page,
}) => {
  await loginAdmin(page);
  await pickSix(page);

  // allInnerTexts() does NOT auto-wait — it answers for the DOM as it stands.
  // Read it straight after a restoration visit and you get [] every time,
  // because Alpine has not re-rendered yet. Settle on the count first, or this
  // compares two empty arrays and passes against ANY build.
  await expect(page.locator(SLOTS)).toHaveCount(6);
  const before = await page.locator(SLOTS).allInnerTexts();
  expect(before.filter((t) => t.trim()).length).toBe(6);

  await leaveAndComeBack(page);

  await expect(page.locator(SLOTS)).toHaveCount(6);
  const after = await page.locator(SLOTS).allInnerTexts();

  const squash = (rows) => rows.map((t) => t.replace(/\s+/g, " ").trim());
  expect(squash(after)).toEqual(squash(before));
});

// A GUEST is the audience a `turbo-cache-control: no-cache` fix would have
// stranded: toggleSelection() returns early on !loggedIn, so their cart never
// reaches the server and a refetched page would have nothing to restore from.
// Carrying the state in the snapshot is what covers them, so it gets a test.
test("a signed-out visitor's picks survive the same journey", async ({ page }) => {
  await pickSix(page);

  await leaveAndComeBack(page);

  await expect(page.locator("body")).toContainText("6 / 6");
  await expect(page.locator(SLOTS)).toHaveCount(6);
});
