const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] The fizz OFF switch.
//
// The flag is set with page.emulateMedia(), NOT `test.use({ reducedMotion })`:
// probed on Playwright 1.58.2 in this repo, the `use` form leaves
// matchMedia("(prefers-reduced-motion: reduce)") false, while emulateMedia and
// browser.newContext both apply it. This assertion spent three runs reporting
// the guard broken when it was fine, because the browser it ran in had never
// been told to prefer less motion.
//
// The guard itself needs !important to beat the state rules inside @utility
// hold-stack (`.hold-stack.fizz-lively .fizz-bit` is more specific than
// anything a media query can write), and that is exactly the kind of thing only
// a browser can check: every server-side assertion passed while a lively button
// kept fizzing at someone who had asked it not to.
test.beforeEach(async ({ page, request }) => {
  await reseed(request);
  await page.emulateMedia({ reducedMotion: "reduce" });
});

test.describe("Hold button fizz under reduced motion", () => {
  test("a viewer who asked for less motion gets no bubbles at all", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/hold_button");

    // Both layers, both variants — the guard covers the lively second layer too.
    expect(await page.evaluate(() => matchMedia("(prefers-reduced-motion: reduce)").matches)).toBe(true);

    const state = await page.evaluate(() =>
      [...document.querySelectorAll(".fizz-bit")].map((el) => {
        const cs = getComputedStyle(el);
        return `${cs.animationName}:${cs.opacity}`;
      })
    );
    expect(state.length).toBeGreaterThan(0);
    expect([...new Set(state)]).toEqual(["none:0"]);

    const extra = await page.evaluate(() =>
      [...document.querySelectorAll(".hold-fizz-extra")].map((el) => getComputedStyle(el).opacity)
    );
    expect([...new Set(extra)]).toEqual(["0"]);
  });
});
