const { test, expect } = require("@playwright/test");
const { login, reseed } = require("./helpers");

// THE CONTESTS TABLE'S PINNED COLUMN HEADER SITS FLUSH UNDER THE NAVBAR
// (/tasks/turf-navbar-avatar-table-header).
//
// The pinned header is studio-engine's sticky table header (config
// .sticky_table_headers): a clone of the <thead>, position: fixed, placed by
// script at the navbar's pinned height. On the scroll-timeline header that
// height is the compact bar, and it is published AFTER the nav-collapse
// controller puts the header on the timeline. Filmed in production: a page
// loaded at a restored scroll position held the clone one band (about 46px)
// below the compact bar, with a table row showing in the gap, until the first
// scroll moved it.
//
// The race is between the controller starting and the clone placing itself,
// so the spec makes it deterministic: the controller's start() is held back,
// the way a busy laptop holds it, and the page is reloaded at a scroll
// position where the header is pinned.
const PLAYER = "mason@mcritchie.studio";
const HEADER = "header[data-navbar-root]";

async function holdController(page, ms) {
  await page.route(/nav_collapse_controller[^/]*\.js/, async (route) => {
    const response = await route.fetch();
    const body = (await response.text()).replace("this.collapse.start()",
      `setTimeout(() => this.collapse && this.collapse.start(), ${ms})`);
    await route.fulfill({ response, body });
  });
}

// The clone's top against the navbar's visible bottom. While the header is
// still collapsing it covers the clone; what matters is that there is never a
// gap, and that once the bar is compact the two meet.
const edges = (page) => page.evaluate(async (sel) => {
  for (let i = 0; i < 2; i++) await new Promise((r) => requestAnimationFrame(r));
  const bar = document.querySelector(sel).getBoundingClientRect().bottom;
  const clone = [...document.querySelectorAll(".sticky-table-header-clone")].find((c) => c.style.display === "block");
  return { y: Math.round(scrollY), bar, clone: clone ? clone.getBoundingClientRect().top : null };
}, HEADER);

test.describe("Contests table header", () => {
  test.beforeEach(async ({ request }) => await reseed(request));

  test("a page loaded at a pinned scroll position shows the column header flush under the bar", async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 420 });
    await login(page, PLAYER);
    await holdController(page, 1200);
    await page.goto("/contests");
    await expect(page.locator(HEADER)).toHaveAttribute("data-nav-timeline-on", "");
    await page.evaluate(() => {
      const head = document.querySelector("table thead");
      window.scrollTo(0, head.getBoundingClientRect().top + scrollY - 10);
    });
    await page.reload();
    await expect(page.locator(HEADER)).toHaveAttribute("data-nav-timeline-on", "");
    await page.waitForTimeout(600);

    const at = await edges(page);
    expect(at.clone, `the column header is pinned ${JSON.stringify(at)}`).not.toBeNull();
    expect(Math.abs(at.clone - at.bar), `flush under the bar, no rows in a gap ${JSON.stringify(at)}`).toBeLessThanOrEqual(1);
  });

  for (const width of [1440, 1280]) {
    test(`at ${width} the column header meets the bar at every frame of a slow scroll and a flick`, async ({ page }) => {
      await page.setViewportSize({ width, height: 420 });
      await login(page, PLAYER);
      await page.goto("/contests");
      await expect(page.locator(HEADER)).toHaveAttribute("data-nav-timeline-on", "");
      await page.waitForLoadState("networkidle");

      const start = await page.evaluate(() => document.querySelector("table thead").getBoundingClientRect().top + scrollY - 200);
      await page.evaluate((y) => window.scrollTo(0, y), Math.max(0, start));
      await page.mouse.move(width / 2, 300);
      const seen = [];
      for (const dy of [12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 12, 240, -60, -12, -12]) {
        await page.mouse.wheel(0, dy);
        seen.push(await edges(page));
      }
      const pinned = seen.filter((s) => s.clone !== null);
      expect(pinned.length, JSON.stringify(seen)).toBeGreaterThan(3);
      for (const s of pinned) {
        expect(s.clone, `never a gap under the bar ${JSON.stringify(s)}`).toBeLessThanOrEqual(s.bar + 1);
      }
      const compact = Math.min(...seen.map((s) => s.bar));
      for (const s of pinned.filter((p) => Math.abs(p.bar - compact) <= 0.5)) {
        expect(Math.abs(s.clone - s.bar), `flush under the compact bar ${JSON.stringify(s)}`).toBeLessThanOrEqual(1);
      }
    });
  }
});
