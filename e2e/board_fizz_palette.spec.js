const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] The board dresses the engine's hold button in the picked teams' colours.
//
// WHAT MOVED, AND WHAT STAYED. studio-engine 0.56 owns the button itself — its
// markup, its press-and-hold timer, its fizz layers and the zone machinery — and
// asserts all of it in its own browser lane, five specs, each mutation-verified.
// This app deleted its copy. What it still owns is the PALETTE: the board's
// fizzPalette getter maps the six picked teams' light / dark / alt colours onto
// the engine's eighteen --fizz-c-* slots, three per zone in pick order, and
// hands them over with :style.
//
// WHY THAT NEEDS A BROWSER. The binding is Alpine reading a getter, and the
// bubbles resolve `--fc: var(--fizz-c-N, <own hue>)`. Both halves are invisible
// to the server: the response carries the getter's SOURCE and each bubble's
// fallback hue, and is byte-identical whether the palette ever lands. Every way
// this can break — the getter throwing, the slot arithmetic drifting from the
// engine's, the engine renaming a slot — shows up only as bubbles wearing their
// fallback candy colours instead of the teams'.
//
// test/integration/hold_button_fizz_palette_test.rb pins the server half (the
// hex reaching the page, both buttons binding the getter). This is the other
// half: the hex actually painting.

const DESKTOP_STACK = '.hold-stack:has(> .hold-btn[data-hold-id="desktop"])';

test.beforeEach(async ({ request }) => await reseed(request));

test("the picked teams' colours resolve onto the button's bubbles", async ({ page }) => {
  await loginAdmin(page);
  await page.goto("/contests/world-cup-2026");
  await page.waitForLoadState("networkidle");

  // Six picks, the way geo_hold_validation.spec.js makes them: the board's own
  // checkbox cards, with the one-shot blur overlay dismissed if it is up.
  const cards = page.locator('[x-data*="selectionBoard"] button[role="checkbox"]:not([disabled])');
  for (let i = 0; i < 6; i++) {
    const blurOverlay = page.locator("div.fixed.inset-0.z-20.cursor-pointer");
    if (await blurOverlay.isVisible({ timeout: 300 }).catch(() => false)) await blurOverlay.click();
    await cards.nth(i).click();
    await expect(page.locator("body")).toContainText(`${i + 1} / 6`);
  }

  // The button only exists once the cart is full — which is the point: the
  // palette is assembled from the picks that made it appear.
  const stack = page.locator(DESKTOP_STACK);
  await expect(stack).toBeVisible();

  const palette = await stack.evaluate((el) => {
    const slots = {};
    for (let i = 1; i <= 18; i++) {
      const value = el.style.getPropertyValue(`--fizz-c-${i}`).trim();
      if (value) slots[i] = value;
    }
    // What the bubbles actually PAINT, grouped by the zone their slot belongs to.
    const zones = {};
    el.querySelectorAll(".fizz-bit").forEach((bit) => {
      const slot = Number(bit.style.getPropertyValue("--fc").match(/--fizz-c-(\d+)/)[1]);
      const zone = Math.ceil(slot / 3);
      const colour = getComputedStyle(bit).backgroundColor;
      zones[zone] = zones[zone] || [];
      if (!zones[zone].includes(colour)) zones[zone].push(colour);
    });
    return { slots, zones, bound: Object.keys(slots).length };
  });

  // Six picks, three colours each: the board fills every slot the engine offers.
  expect(palette.bound).toBe(18);
  Object.values(palette.slots).forEach((colour) => {
    expect(colour, "a bound slot must carry a real hex, never an empty string").toMatch(/^#[0-9a-f]{6}$/i);
  });

  // And the bubbles wear them. A zone resolving to more than three colours means
  // the bubbles fell back to their own hues — the exact failure a server-side
  // assertion cannot see.
  expect(Object.keys(palette.zones)).toHaveLength(6);
  for (const [zone, colours] of Object.entries(palette.zones)) {
    expect(colours.length, `zone ${zone} paints its own team's colours`).toBeLessThanOrEqual(3);
    const hexes = Object.entries(palette.slots)
      .filter(([slot]) => Math.ceil(Number(slot) / 3) === Number(zone))
      .map(([, hex]) => hex.toLowerCase());
    const painted = colours.map((rgb) => {
      const [r, g, b] = rgb.match(/\d+/g).map(Number);
      return `#${[r, g, b].map((n) => n.toString(16).padStart(2, "0")).join("")}`;
    });
    painted.forEach((hex) => {
      expect(hexes, `zone ${zone} painted ${hex}, which is not one of its team's colours`).toContain(hex);
    });
  }
});
