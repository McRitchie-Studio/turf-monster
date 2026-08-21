// THE LANE'S MOTION ENVIRONMENT, ASSERTED RATHER THAN BELIEVED.
//
// playwright.config.js has declared `reducedMotion: "reduce"` for months and it
// DID NOT REACH THE PAGE. Written as a bare `use.reducedMotion` key it is inert
// in Playwright 1.58.2; only `use.contextOptions.reducedMotion` applies. So every
// spec ran at the browser default while the config said the opposite, and any
// spec written believing motion was off was measuring something other than it
// thought. (The catalogued casualty: .legendary-badge pans its gradient forever,
// so a screenshot crop containing the disc differs on EVERY frame and an
// assertion built on one can never fail — see e2e/navbar_layout.spec.js.)
//
// WHY THIS FILE EXISTS, AND WHY IT IS NOT A CONFIG-TEXT TEST. A test that greps
// playwright.config.js for a string proves the string is there — which was ALREADY
// TRUE the whole time the setting did nothing. Reading the config is not evidence
// about the browser. The only thing that is: ask a real page, running under the
// real config, through the real runner.
//
// So the guard below asks TWO different witnesses, because each covers the
// other's blind spot:
//
//   JS   — matchMedia(...).matches, the flag every inline script in this app
//          branches on (contests/live.html.erb:18, contests/_chat_panel.html.erb:288,
//          modals/_onboarding.html.erb:67).
//   CSS  — whether the STYLE ENGINE honors the query, measured by animating a
//          probe element that a @media block is supposed to silence. matchMedia
//          could in principle report true while the cascade ignored it, and it is
//          the cascade that nine blocks in app/assets/tailwind/application.css
//          depend on. getAnimations() reads the timeline actually driving paint.
//
// MUTATION-PROVEN: revert playwright.config.js to the bare `reducedMotion:` key
// and both witnesses go red (measured — see the task's control line).
const { test, expect } = require("@playwright/test");
const { allowMotion } = require("./helpers");

const QUERY = "(prefers-reduced-motion: reduce)";

const matchesReduced = (page) => page.evaluate((q) => matchMedia(q).matches, QUERY);

// Animate a probe, then let a @media (prefers-reduced-motion: reduce) block try
// to silence it. Returns how many animations are actually running on it: 0 means
// the cascade honored the query, 1 means it did not.
const runningAnimationsOnProbe = (page) =>
  page.evaluate(() => {
    const style = document.createElement("style");
    style.textContent = `
      @keyframes rm-probe-spin { from { opacity: 1; } to { opacity: 0.5; } }
      .rm-probe { animation: rm-probe-spin 10s linear infinite; }
      @media (prefers-reduced-motion: reduce) { .rm-probe { animation: none; } }
    `;
    document.head.appendChild(style);
    const el = document.createElement("div");
    el.className = "rm-probe";
    el.textContent = "probe";
    document.body.appendChild(el);
    // Force style/layout so the animation is started before we read it.
    void el.offsetHeight;
    return el.getAnimations().length;
  });

test("playwright.config.js's reducedMotion setting REACHES the page", async ({ page }) => {
  await page.goto("/");

  expect(
    await matchesReduced(page),
    "playwright.config.js declares reduced motion for this lane, but matchMedia " +
      "says the page is not under it. The setting is inert again — it belongs in " +
      "`use.contextOptions.reducedMotion`, NOT the bare `use.reducedMotion` key."
  ).toBe(true);

  expect(
    await runningAnimationsOnProbe(page),
    "matchMedia agrees the page is reduced-motion, but the STYLE ENGINE ignored " +
      "the @media block — a probe animation a `@media (prefers-reduced-motion: " +
      "reduce)` rule silences is still running. Nine blocks in " +
      "app/assets/tailwind/application.css depend on this cascade."
  ).toBe(0);
});

test("allowMotion() gives a spec its animations back, explicitly", async ({ page }) => {
  // The other half of the contract. Reduced motion is the lane's real default
  // now, so specs that assert a RUNNING timeline (the glow replay in
  // navbar_layout.spec.js) opt out through this one helper. If the opt-out
  // stopped working those specs would fail far away from the cause; fail here.
  await page.goto("/");
  expect(await matchesReduced(page), "the lane must start reduced").toBe(true);

  await allowMotion(page);

  expect(
    await matchesReduced(page),
    "allowMotion(page) must lift the lane's reduced-motion default"
  ).toBe(false);
  expect(
    await runningAnimationsOnProbe(page),
    "after allowMotion(page) a @media-guarded animation must run again"
  ).toBe(1);
});
