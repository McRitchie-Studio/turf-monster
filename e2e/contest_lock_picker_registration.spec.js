const { test, expect } = require("@playwright/test");
const { loginAdmin } = require("./helpers");

// [e2e] ONE contestLockPicker definition, live on BOTH arrival paths.
//
// WHY A BROWSER IS THE ONLY WITNESS, AND WHY BOTH PATHS. This app registers
// Alpine factories as inline `window.X = function` in shared/_alpine_factories,
// because importmap modules execute AFTER Alpine has already walked x-data.
// While a SECOND copy of this factory lived in app/javascript/contest_lock_picker.js,
// the page you got depended on how you arrived — measured 2026-09-16:
//
//   direct page.goto      -> Alpine resolved x-data from the window global set at
//                            parse time = the ERB copy, which had NO lockViaPhantom.
//                            The on-chain lock button was inert on a fresh load.
//   Turbo client-side nav -> the module's Alpine.data() registration (added by the
//                            PR that introduced the divergence) had landed by then
//                            and takes precedence, so the MODULE copy answered.
//
// Neither a bare partial render nor a read of window.contestLockPicker can see
// that split: the global is re-clobbered by whichever script ran last, which is
// a DIFFERENT object from the one Alpine bound to the element. So this spec
// reads the LIVE COMPONENT off the element, on each path, and nothing else.
const PICKER = '[x-data*="contestLockPicker"]';

// The live component Alpine bound to the element — not the window global.
function liveComponent() {
  const el = document.querySelector('[x-data*="contestLockPicker"]');
  if (!el) return { error: "no picker element" };
  const data = (window.Alpine && window.Alpine.$data && window.Alpine.$data(el)) ||
               (el._x_dataStack && el._x_dataStack[0]);
  if (!data) return { error: "no Alpine data bound to picker" };
  return {
    pickedUnix: typeof data.pickedUnix,
    lockViaPhantom: typeof data.lockViaPhantom,
    clearLockViaPhantom: typeof data.clearLockViaPhantom,
    // A control: present in BOTH copies. If this ever reads "undefined" the
    // component failed to bind at all and the three above are vacuously equal.
    isToday: typeof data.isToday,
  };
}

const FULL = {
  pickedUnix: "function",
  lockViaPhantom: "function",
  clearLockViaPhantom: "function",
  isToday: "function",
};

test.describe("contestLockPicker registration", () => {
  test("the picker is whole on a direct page load @smoke", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/contests/new");
    await page.waitForSelector(PICKER);
    expect(await page.evaluate(liveComponent)).toEqual(FULL);
  });

  test("the picker is whole after a Turbo client-side navigation", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/contests");

    // PIN THE TRANSITION, NOT THE DESTINATION. A Turbo visit that silently fell
    // back to a full document load would re-run the parse-time scripts and test
    // the SAME path as the spec above, passing while asserting nothing about
    // client-side navigation. This sentinel dies with the document, so its
    // survival is the proof the navigation stayed client-side.
    await page.evaluate(() => { window.__sameDocument = true; });
    await page.evaluate(() => window.Turbo.visit("/contests/new"));
    await page.waitForSelector(PICKER);
    expect(await page.evaluate(() => window.__sameDocument)).toBe(true);

    expect(await page.evaluate(liveComponent)).toEqual(FULL);
  });
});
