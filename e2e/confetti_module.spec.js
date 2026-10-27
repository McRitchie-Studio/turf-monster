const { test, expect } = require("@playwright/test");
const { requireStudioTooling } = require("./studio_tooling");
const { watchPageErrors } = requireStudioTooling("e2e_helpers.js");

// [e2e] Turf's three celebrations fire through studio-engine's
// studio/studio_confetti module (0.115.1), in a real page.
//
// fireConfettiFromBadge lives in solana_utils.js, an importmap module that
// imports the module statically; fireQuestBadgeConfetti and fireFreeEntryConfetti
// live in shared/_alpine_factories, a classic inline script that reaches it with
// import(). The module's confetti() reads canvas-confetti's global at call time,
// so a stand-in installed after load counts every burst that gets through. Each
// celebration is a burst and a follow-up shell, so three make six.
//
// This proves the wiring works in a browser (the import() resolves under the
// page's CSP, and every burst arrives). It cannot tell the module from the
// deprecated global, since both end at canvas-confetti's window.confetti; the
// unit tier holds that (test/javascript/solana_utils_confetti.test.mjs and
// test/views/confetti_module_adoption_test.rb).
//
// watchPageErrors (the engine's shared helper) holds the page to no error: a
// bare specifier the map could not resolve, or an import() a strict CSP refused,
// would surface there.
test("the three celebrations reach canvas-confetti through studio/studio_confetti", async ({ page }) => {
  const errors = watchPageErrors(page, { ownOriginOnly: true });
  await page.goto("/help");
  await page.waitForLoadState("load");

  await page.evaluate(() => {
    window.__bursts = [];
    window.confetti = (options) => { window.__bursts.push(options); return null; };
  });
  await page.evaluate(() => {
    window.fireConfettiFromBadge();
    window.fireQuestBadgeConfetti();
    window.fireFreeEntryConfetti();
  });

  await expect.poll(() => page.evaluate(() => window.__bursts.length)).toBe(6);
  const bursts = await page.evaluate(() => window.__bursts);
  for (const burst of bursts) {
    expect(typeof burst.zIndex, "each burst carries a --z-alert tier as a number").toBe("number");
    expect(burst.colors.length).toBeGreaterThan(0);
  }
  expect(errors).toEqual([]);
});
