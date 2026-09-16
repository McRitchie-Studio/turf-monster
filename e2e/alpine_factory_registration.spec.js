const { test, expect } = require("@playwright/test");
const { loginAdmin } = require("./helpers");

// [e2e] ONE definition per Alpine factory, live on BOTH arrival paths.
//
// The companion to test/views/alpine_factory_definitions_test.rb. That one scans
// SOURCE and fails the moment a second definition appears. This one reads the
// BROWSER and proves the definition that survived is the one Alpine actually
// binds — on a fresh document and on a Turbo client-side navigation, which in
// this app are two different resolution orders.
//
// WHY READING window.<name> PROVES NOTHING. The global is a different object
// from the one Alpine bound to the element, and it inverts the other way. All of
// this was measured on 2026-09-16 while these three twins still existed
// (task paired-alpine-factories-can-diverge), reading Alpine.$data(el):
//
//   component          direct page.goto   Turbo client-side nav
//   entryTokenBadge    inline copy        MODULE copy
//   cardListFilter     inline copy        MODULE copy
//   seedsBar           inline copy        inline copy
//
// seedsBar did not invert, and the reason is worth keeping: its factory ships in
// the SAME partial as its call site, so every mount re-installs the definition
// just before Alpine evaluates the x-data beside it. window.seedsBar meanwhile
// read as the MODULE copy between importmap load and the next seeds-bar render —
// so a spec asserting on the global would have reported the wrong copy live while
// the page was correct, the mirror image of the contestLockPicker spec that
// stayed green through a real user-facing break.
//
// The three factories are no longer paired, so a copy-vs-copy assertion has
// nothing left to compare. What these specs pin instead is the property that
// broke when a twin won: the component Alpine bound is WHOLE, on both paths.
// For seedsBar "whole" is exactly what the deleted module lacked.

const SEEDS = '[x-data="seedsBar()"]';
const BADGE = '[x-data*="entryTokenBadge"]';
const FILTER = '[x-data*="cardListFilter"]';
const ATTACHED = { state: "attached" };

// The live component Alpine bound to the element — never the window global.
//
// ASSERT ON FUNCTION SOURCE, NOT ON A PROPERTY. Alpine.$data(el) returns the
// element's whole data stack MERGED, so a bare property read can be satisfied by
// an ANCESTOR scope rather than by the component under test. Measured while the
// control twin below was armed: the modal's bar had bound the stale module copy,
// yet `typeof d._serverSeedsTotal` still answered "number" — the value was
// sitting on a different frame of the stack (`_x_dataStack` read back as
// [<module keys>, {}, {}, {}, {_serverSeedsTotal}]). A property assertion would
// have passed on a component that was genuinely wrong. The methods below are own
// properties of the bound factory, so their SOURCE is the copy that is live.
function liveShape(sel) {
  const el = document.querySelector(sel);
  if (!el) return { error: "element not found: " + sel };
  const d =
    (window.Alpine && window.Alpine.$data && window.Alpine.$data(el)) ||
    (el._x_dataStack && el._x_dataStack[0]);
  if (!d) return { error: "no Alpine data bound to " + sel };
  const src = (fn) => (typeof fn === "function" ? fn.toString() : "");
  return {
    // The two things the deleted module copy did NOT have: init() read no
    // server total, and normalStart() still ran the old unconditional
    // `if (data)` instead of reconciling cache against server.
    initReadsServerTotal: /_serverSeedsTotal/.test(src(d.init)),
    reconciles: /cacheTotal/.test(src(d.normalStart)),
    // A control: present in BOTH copies. If this reads "undefined" the component
    // never bound and the two assertions above are vacuously satisfied.
    control: typeof d.handleSeedsUpdate,
  };
}

const SEEDS_WHOLE = { initReadsServerTotal: true, reconciles: true, control: "function" };

// PIN THE TRANSITION, NOT THE DESTINATION. A Turbo visit that silently fell back
// to a full document load would re-run the parse-time scripts and re-test the
// direct-load path, passing while asserting nothing about client-side
// navigation. This sentinel dies with the document, so its survival IS the proof
// the navigation stayed same-document.
async function turboVisit(page, path, selector) {
  await page.evaluate((s) => {
    window.__sameDocument = true;
    // The ORIGIN page can carry the same selector (the navbar's seeds bar, the
    // gear sidebar's badge), so a bare wait for it resolves before Turbo renders.
    document.querySelectorAll(s).forEach((el) => (el.__beforeVisit = true));
  }, selector);
  await page.evaluate((p) => window.Turbo.visit(p), path);
  await page.waitForFunction((s) => {
    const el = document.querySelector(s);
    return !!el && !el.__beforeVisit && !!el._x_dataStack;
  }, selector);
  expect(await page.evaluate(() => window.__sameDocument)).toBe(true);
}

test.describe("Alpine factory registration", () => {
  test("seedsBar is whole on a direct page load @smoke", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/account");
    await page.waitForSelector(SEEDS, ATTACHED);
    expect(await page.evaluate(liveShape, SEEDS)).toEqual(SEEDS_WHOLE);
  });

  test("seedsBar is whole after a Turbo client-side navigation", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/account");
    await turboVisit(page, "/contests", SEEDS);
    expect(await page.evaluate(liveShape, SEEDS)).toEqual(SEEDS_WHOLE);
  });

  // THE MOUNT THE "late re-assign is inert" CARVE-OUT DOES NOT COVER. The bars
  // above were bound at Alpine's initial walk, so a global re-assigned after
  // that walk could not reach them. This one is inserted into the document long
  // after the importmap has run — the modal host clones its card out of a
  // template x-if — so it resolves the factory at MOUNT time, whatever the
  // global happens to hold by then.
  test("seedsBar is whole inside a lazily-inserted modal", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/account");
    await page.waitForSelector(SEEDS, ATTACHED);

    await page.evaluate(() =>
      window.Alpine.store("modals").open("quest-success", {
        seeds_earned: 25,
        seeds_total: 125,
        seeds_level: 2,
      })
    );
    const modalSeeds = `[role=dialog] ${SEEDS}`;
    await page.waitForSelector(modalSeeds, ATTACHED);
    expect(await page.evaluate(liveShape, modalSeeds)).toEqual(SEEDS_WHOLE);
  });

  // entryTokenBadge and cardListFilter had twins that were byte-identical, so
  // there is no behaviour these can compare — the source scan owns the
  // single-definition invariant for them. What a browser can still prove, and
  // what a module-only factory would fail, is that the component BINDS on the
  // path importmap timing breaks: a fresh document.
  test("entryTokenBadge binds on both arrival paths", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/account");
    await page.waitForSelector(BADGE, ATTACHED);
    const shape = () => {
      const el = document.querySelector('[x-data*="entryTokenBadge"]');
      const d = el._x_dataStack[0]; // own frame: $data merges ancestors, which can hold these keys
      return { count: typeof d.count, init: typeof d.init, destroy: typeof d.destroy };
    };
    const WHOLE = { count: "number", init: "function", destroy: "function" };
    expect(await page.evaluate(shape)).toEqual(WHOLE);

    await turboVisit(page, "/contests", BADGE);
    expect(await page.evaluate(shape)).toEqual(WHOLE);
  });

  test("cardListFilter binds on both arrival paths", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/teams");
    await page.waitForSelector(FILTER, ATTACHED);
    const shape = () => {
      const el = document.querySelector('[x-data*="cardListFilter"]');
      const d = el._x_dataStack[0]; // own frame: $data merges ancestors, which can hold these keys
      return {
        search: typeof d.search,
        apply: typeof d.apply,
        visibleCount: typeof d.visibleCount,
      };
    };
    const WHOLE = { search: "string", apply: "function", visibleCount: "number" };
    expect(await page.evaluate(shape)).toEqual(WHOLE);

    await page.goto("/contests");
    await turboVisit(page, "/teams", FILTER);
    expect(await page.evaluate(shape)).toEqual(WHOLE);
  });
});
