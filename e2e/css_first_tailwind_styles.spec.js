const { test, expect } = require("@playwright/test");
const { reseed } = require("./helpers");

// Turf builds Tailwind CSS-first (/tasks/turf-adopts-css-first-tailwind): no
// config/tailwind.config.js and no @config; the theme tokens, the gem's @source
// scan and the motion layer all arrive through studio-engine's host.css.
// test/lib/tailwind_css_first_test.rb guards the source and the compiled file;
// this proves, in a browser, that the pages people watch most still come out
// styled at a phone and a desktop width, and that no asset request fails.

const WIDTHS = [390, 1280];
const PAGES = {
  "contest page": "/contests/world-cup-2026/contest",
  "live board": "/contests/world-cup-2026",
  "league board": "/live",
};

async function styleFacts(page) {
  return page.evaluate(() => {
    const selectors = new Set();
    for (const sheet of document.styleSheets) {
      let rules;
      try { rules = sheet.cssRules; } catch (_) { continue; }
      const walk = (list) => {
        for (const rule of list) {
          if (rule.selectorText) rule.selectorText.split(",").forEach((s) => selectors.add(s.trim()));
          if (rule.cssRules) walk(rule.cssRules);
        }
      };
      walk(rules);
    }
    const surface = document.querySelector(".bg-surface");
    return {
      font: getComputedStyle(document.body).fontFamily,
      surfaceBg: surface ? getComputedStyle(surface).backgroundColor : null,
      // engine theme.css, Turf's own @theme block, engine-motion.css
      bgSurface: selectors.has(".bg-surface"),
      textPrimary: selectors.has(".text-primary"),
      textVioletInk: selectors.has(".text-violet-ink"),
      spinner: selectors.has(".spinner"),
    };
  });
}

for (const [name, path] of Object.entries(PAGES)) {
  test(`the ${name} renders styled at 390 and 1280 with no failed asset`, async ({ page, request }) => {
    await reseed(request);
    const failed = [];
    let stylesheet = null;
    page.on("response", (res) => {
      const url = new URL(res.url());
      if (!url.pathname.startsWith("/assets/")) return;
      if (/\/assets\/tailwind-[0-9a-f]+\.css$/.test(url.pathname)) stylesheet = res.status();
      if (res.status() >= 400) failed.push(`${res.status()} ${url.pathname}`);
    });

    for (const width of WIDTHS) {
      await page.setViewportSize({ width, height: 900 });
      const res = await page.goto(path);
      expect(res.status(), `${path} at ${width}`).toBeLessThan(400);
      await page.waitForLoadState("load");

      const facts = await styleFacts(page);
      expect(facts.font, `Montserrat from the engine's theme.css at ${width}`).toContain("Montserrat");
      expect(facts.bgSurface, ".bg-surface (engine theme.css)").toBe(true);
      expect(facts.textPrimary, ".text-primary (Turf's @theme block)").toBe(true);
      expect(facts.textVioletInk, ".text-violet-ink (Turf's @theme block)").toBe(true);
      expect(facts.spinner, ".spinner (engine-motion.css)").toBe(true);
      if (facts.surfaceBg !== null) {
        expect(facts.surfaceBg, "a .bg-surface element paints a background").not.toBe("rgba(0, 0, 0, 0)");
      }
    }

    expect(stylesheet, "the compiled tailwind stylesheet loaded").toBe(200);
    expect(failed, "asset requests that failed").toEqual([]);
  });
}
