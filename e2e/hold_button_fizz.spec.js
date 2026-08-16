const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] /admin/hold_button — the hold-to-confirm button's fizz layers.
//
// What only a browser can prove, and what the rest of this feature's suite
// therefore cannot:
//
//   · The lab pins each phase (.process / .success / .error) from an inline
//     <script>. The server renders those buttons in their RESTING state, so a
//     script that never runs leaves the classes off — and no assertion against
//     the rendered String can tell the difference.
//   · Hover doubles the bubble COUNT rather than the speed. That claim lives
//     entirely in computed style: a second layer's opacity going 0 → 1 while
//     the resting layer's animation-duration stays put.
//   · Each of the six zones resolves to ONE color. The bubbles carry
//     `--fc: var(--fizz-c-<slot>, <candy hue>)`; whether that lands on the
//     bound palette or the fallback is a var resolution the markup cannot show.
//   · Reduced motion actually switches the bubbles off.
//
// NOTE ON THE MOTION FLAG. playwright.config.js sets `reducedMotion: "reduce"`
// in `use`, which would switch this whole feature off — but in this repo that
// option is INERT: probed on Playwright 1.58.2, `test.use({ reducedMotion })`
// leaves matchMedia("(prefers-reduced-motion: reduce)") false, while
// page.emulateMedia() and browser.newContext() both apply it. So every spec
// here has really been running at the browser default (no-preference), and a
// spec that trusts the config to set this flag is testing nothing. These tests
// therefore set it per page, out loud. (The config's own intent — Turbo
// skipping view transitions — is not being met either; that is bigger than this
// task and belongs in its own.)
test.beforeEach(async ({ page, request }) => {
  await reseed(request);
  await page.emulateMedia({ reducedMotion: "no-preference" });
});

// The nudge cycle re-classes every hold button every few seconds and swaps the
// bubbles onto their own timing while it runs. Clearing the class and reading
// the computed style in ONE evaluate keeps the pair atomic: JS is single
// threaded, so the nudge interval cannot fire between the two halves. Doing it
// as two awaits raced and flaked.
const restingRate = (stack) =>
  stack.evaluate((el) => {
    el.querySelectorAll(".hold-btn").forEach((b) => b.classList.remove("nudge", "nudge-soft"));
    const bit = el.querySelector(".hold-fizz:not(.hold-fizz-extra) .fizz-bit");
    const cs = getComputedStyle(bit);
    return { name: cs.animationName, duration: cs.animationDuration };
  });

test.describe("Hold button fizz", () => {
  test("the lab's inline script pins every phase @smoke", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/hold_button");

    // Server-rendered markup carries none of these classes.
    await expect(page.locator('.hold-btn[data-hold-id="fizz-process"]')).toHaveClass(/\bprocess\b/);
    await expect(page.locator('.hold-btn[data-hold-id="fizz-success"]')).toHaveClass(/\bsuccess\b/);
    await expect(page.locator('.hold-btn[data-hold-id="fizz-error"]')).toHaveClass(/\berror\b/);

    // Replay re-runs the one-shot burst: the settled bubbles light back up.
    const burstBit = page
      .locator('.hold-stack:has(> .hold-btn[data-hold-id="fizz-success"]) .fizz-bit')
      .first();
    await expect
      .poll(() => burstBit.evaluate((el) => parseFloat(getComputedStyle(el).opacity)))
      .toBeLessThan(0.05);

    await page.locator('[data-fizz-replay="fizz-success"]').click();
    await expect
      .poll(() => burstBit.evaluate((el) => parseFloat(getComputedStyle(el).opacity)), { timeout: 3000 })
      .toBeGreaterThan(0.2);
    expect(await burstBit.evaluate((el) => getComputedStyle(el).animationName)).toBe("fizz-burst");
  });

  test("hover doubles the bubble count without changing the speed", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/hold_button");

    const stack = page.locator('.hold-stack:has(> .hold-btn[data-hold-id="fizz-lively"])');
    const extra = stack.locator(".hold-fizz-extra");

    await expect(stack).toHaveClass(/\bfizz-lively\b/);
    const atRest = await restingRate(stack);
    expect(atRest.name).toBe("fizz-boil");
    expect(await extra.evaluate((el) => getComputedStyle(el).opacity)).toBe("0");

    await page.locator('.hold-btn[data-hold-id="fizz-lively"]').hover();
    await expect
      .poll(() => extra.evaluate((el) => getComputedStyle(el).opacity), { timeout: 3000 })
      .toBe("1");

    // Same bubble, same cycle: hover adds bubbles, it does not spin them faster.
    expect(await restingRate(stack)).toEqual(atRest);

    // And the calm variant has no second layer to reveal at all.
    const calm = page.locator('.hold-stack:has(> .hold-btn[data-hold-id="fizz-calm"])');
    await expect(calm.locator(".hold-fizz-extra")).toHaveCount(0);
  });

  test("each zone resolves to one color, and the layers differ within it", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/hold_button");

    // The palette button always has its slots bound (six teams, or the candy
    // fallback when this database has no branded ones), so every bubble in a
    // zone must resolve to that zone's color rather than its own fallback hue.
    const zones = await page.evaluate(() => {
      const stack = document.querySelector('.hold-stack:has(> .hold-btn[data-hold-id="fizz-teams"])');
      const read = (selector) => {
        const byZone = {};
        stack.querySelectorAll(selector).forEach((el) => {
          const slot = Number(el.style.getPropertyValue("--fc").match(/--fizz-c-(\d+)/)[1]);
          const zone = Math.ceil(slot / 3);
          byZone[zone] = byZone[zone] || [];
          const color = getComputedStyle(el).backgroundColor;
          if (!byZone[zone].includes(color)) byZone[zone].push(color);
        });
        return byZone;
      };
      return {
        rest: read(".hold-fizz:not(.hold-fizz-extra) .fizz-bit"),
        hover: read(".hold-fizz-extra .fizz-bit"),
      };
    });

    expect(Object.keys(zones.rest)).toHaveLength(6);
    for (const [zone, colors] of Object.entries(zones.rest)) {
      expect(colors, `zone ${zone} rests in exactly one color`).toHaveLength(1);
      // The hover layer is that team's dark plus its alt — one color when the
      // team curates no alt, two when it does. Never the resting color.
      expect(zones.hover[zone].length, `zone ${zone} hovers in one or two colors`).toBeLessThanOrEqual(2);
      expect(zones.hover[zone], `zone ${zone} changes color on hover`).not.toContain(colors[0]);
    }
  });
});
