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

// WAIT FOR THE NAVIGATION TO FINISH, NOT FOR THE URL TO FLIP.
//
// Turbo changes the URL at before-render, BEFORE the body swap and before the
// outgoing snapshot is filed, so waitForURL() alone returns mid-visit.
//
// USE THIS SPARINGLY AND ON PURPOSE. It is NOT a general "make it less flaky"
// wait -- on the leaveAndComeBack leg it hides the bug this whole file exists for
// (measured: with a settle there the spec passes with the module unimported). It
// belongs only where a leg puts TWO history traversals in flight at once, because
// two visits rendering concurrently resolve in nondeterministic order and file
// snapshots under the wrong URL -- the second failure mode written up in
// app/javascript/turbo_snapshot_cache.js, which no page-level fix closes.
//
// The forward leg below is that case, and it needs the wait to mean what it says:
// it claims "going forward caches the contest page a second time", and unsettled
// that second cache write never happened at all -- the forward visit was preempted
// before it rendered.
async function settle(page) {
  await page.evaluate(
    () =>
      new Promise((resolve) => {
        // The visit may already have finished during the round trip into the page,
        // in which case turbo:load has fired and waiting for another one would hang
        // until the spec timeout. navigator.currentVisit is Turbo's own record of a
        // visit in flight, and it is cleared when the visit completes.
        const visit =
          window.Turbo &&
          window.Turbo.session &&
          window.Turbo.session.navigator &&
          window.Turbo.session.navigator.currentVisit;
        if (!visit) return resolve();

        document.addEventListener("turbo:load", () => resolve(), { once: true });
        // Never let a missed event turn into a 30s spec timeout with no clue why.
        setTimeout(resolve, 3000);
      })
  );
}

async function leaveAndComeBack(page) {
  // A real Turbo visit and a real restoration visit. page.goto() is a full
  // browser load that never touches the snapshot cache, so it would pass
  // against the broken build.
  // DELIBERATELY NOT SETTLED. Back is pressed as soon as the URL flips, while the
  // outgoing snapshot is still unfiled -- that is the whole bug, and settling here
  // hides it completely: with a settle on this leg the spec passes even with
  // app/javascript/turbo_snapshot_cache.js unimported. Verified both ways.
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
//
// AND IT RUNS UNDER THE LANE'S REAL REDUCED-MOTION DEFAULT. It used to call
// allowMotion(page) to park a finding from /tasks/make-reduced-motion-reach-specs;
// that opt-out is gone, because the bug it parked is fixed in
// app/javascript/turbo_snapshot_cache.js. Turbo files its snapshot one macrotask
// after turbo:before-cache and swaps the body on an unordered animation frame, so
// on a page this size the swap won and the snapshot was still unfiled when Back
// was pressed -- Turbo then went to the network and served the guest a fresh page
// with an empty cart. Turbo disables view transitions under reduced motion
// (turbo.js `prefersViewTransitions`), and it was their ~30ms of setup that had
// been hiding the race; the engine's ::view-transition-* rule never enters into it.
//
// DO NOT reintroduce allowMotion(page) here. Motion-on is the configuration in
// which this bug is invisible, so a green run under it proves nothing.
//
// The forward-then-back leg at the bottom covers a SECOND, separate failure --
// Turbo filing the outgoing DOM under the wrong URL when a history traversal
// lands inside a render. Holding the render does not fix that one and is what
// exposes it; the re-stamp handler in turbo_snapshot_cache.js is its fix.
test("a signed-out visitor's picks survive the same journey", async ({ page }) => {
  await pickSix(page);

  await leaveAndComeBack(page);

  await expect(page.locator("body")).toContainText("6 / 6");
  await expect(page.locator(SLOTS)).toHaveCount(6);

  // FORWARD, then BACK again. The snapshot has to survive being RE-cached, not just
  // written once: going forward caches the contest page a second time, this time
  // from a DOM Alpine rebuilt out of the restored snapshot, and that second copy is
  // what this Back reads. An ordering fix that only covers the first cache write
  // passes everything above and fails here.
  //
  // The count carries the claim on this leg, and only on this leg: the assertions
  // above already proved on THIS page that six counted slots are six FILLED slots,
  // so what is left to establish is that the same cart came back a second time.
  await page.goForward();
  await page.waitForURL((u) => !u.pathname.startsWith("/contests"));
  await settle(page);
  await page.goBack();
  await page.waitForURL((u) => u.pathname.startsWith("/contests"));
  await settle(page);

  // TWO CLAIMS, AND THE SECOND ONE IS WHY THIS LEG EXISTS: the cart ARRIVES,
  // and then it STAYS.
  //
  // The failure mode here is a LATE swap. The restore lands correctly within a
  // few ms and is REPLACED about 200ms later by the page we came forward from.
  // Measured on the broken build: slots=6 at +4ms, then slots=0 from +208ms
  // through +3.9s, document.title "Turf Totals v1 - How It Works",
  // #entry-sidebar gone entirely. A plain toContainText GREENS all of that --
  // its first probe lands inside the good window, passes, and never looks
  // again. So a first-probe assertion cannot fail on this bug, which makes it
  // worthless here however strict its selector is.
  //
  // Hence: retry until the restore has landed (below), then SAMPLE for 1200ms
  // and keep the WORST reading. Order matters -- sampling from before the
  // restoration render completes would catch the legitimate mid-swap DOM and
  // report a false 0.
  await expect(page.locator(SLOTS)).toHaveCount(6);

  const settled = await page.evaluate(async (slots) => {
    const deadline = Date.now() + 1200;
    let sawSidebar = true;
    let sawRulesPage = false;
    while (Date.now() < deadline) {
      sawSidebar = sawSidebar && !!document.querySelector("#entry-sidebar");
      sawRulesPage = sawRulesPage || document.title.includes("How It Works");
      await new Promise((resolve) => setTimeout(resolve, 16));
    }
    return { sawSidebar, sawRulesPage, finalSlots: document.querySelectorAll(slots).length };
  }, SLOTS);

  // PAGE IDENTITY, sampled the whole way. The bug's signature is durable and
  // page-level -- #entry-sidebar gone and the Rules title in place, held for
  // seconds -- so these two catch it without being fooled by a one-frame
  // Alpine x-for rebuild trough, which does momentarily drop the slot count on
  // a HEALTHY restore and is not what this leg is about.
  expect(settled.sawSidebar, "#entry-sidebar vanished after the restore landed").toBe(true);
  expect(settled.sawRulesPage, "the Rules page was swapped in under the contest URL").toBe(false);

  // And the cart is still counted once the dust has settled, not merely on the
  // first probe.
  expect(settled.finalSlots, "the restored cart did not survive the settle").toBe(6);

  await expect(page.locator("body")).toContainText("6 / 6");
  await expect(page.locator(SLOTS)).toHaveCount(6);
});
