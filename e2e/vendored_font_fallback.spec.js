const { test, expect } = require("@playwright/test");
const { login } = require("./helpers");

// studio-engine 0.56.3 stopped loading Montserrat from fonts.googleapis.com and
// self-hosts it through the asset pipeline at `font-display: optional`. Two
// separate properties fall out of that, and this file holds one spec for each,
// because the first passing tells you nothing about the second.
//
// PROPERTY 1 — the vendored face genuinely resolves in THIS app. The engine
// verified it in its own dummy app and the hub verified it in the hub; neither
// says anything about turf-monster's pipeline, and a font that 404s here would
// be invisible except as "the site looks slightly wrong". Asserted on the SERVED
// BYTES (status, content-type, length) rather than on a computed style, because
// a computed `font-family: Montserrat` is what the CSS says, not what the
// browser painted.
//
// PROPERTY 2 — the chrome is contained when the page paints in the FALLBACK
// face. This is the one that broke. `optional` has no swap period: a face that
// is not ready inside the browser's ~100ms block period is abandoned for that
// entire navigation, so the page renders in `system-ui, sans-serif` and never
// swaps. The engine names that cost on purpose. It means "renders in the
// fallback face" is a SUPPORTED state, not an error state, and any layout that
// only fits in Montserrat's metrics is broken for every visitor who lands in it.
//
// That is exactly how this regressed. e2e/navbar_layout.spec.js measures
// whatever face the runner happens to paint: macOS resolves system-ui to a face
// NARROWER than Montserrat, so it stayed green locally, while the Linux CI
// runner resolves it to a WIDER one and the header spilled 4px past the
// viewport (documentOverflow 4, deterministic across both retries). A spec that
// depends on the runner's system font to expose the defect is a spec that only
// fails on half the fleet, so this one forces the face instead of hoping for it.
const VIEWPORTS = [
  { width: 1366, height: 800 },
  { width: 1024, height: 768 },
  { width: 820, height: 768 },
];

// The stack the page really falls back to when `optional` abandons Montserrat —
// read off the compiled `font-family: Montserrat, system-ui, sans-serif`.
const FALLBACK_STACK = "system-ui, sans-serif";

// TWO ASSERTIONS, AND THE SECOND IS THE ONE THAT TRAVELS. documentOverflow is
// the symptom the release actually tripped over, but it can only fire where the
// fallback face is WIDER than Montserrat — true on the Linux runner, false on
// macOS, which is the whole reason this shipped. So the spec also asserts the
// MECHANISM: that no banner tooltip's content is wider than its own box. That
// one is font-independent and platform-independent — pre-fix the tooltip
// measured 263px of unbreakable line inside a 260px cap in Montserrat itself —
// so it bites on any machine, and it names the defect rather than its side
// effect. Two earlier attempts to make the symptom portable are recorded here so
// nobody spends the afternoon again: forcing a named wide face (`Verdana,
// 'DejaVu Sans', sans-serif`) reds on CI for reasons about the runner's font
// inventory rather than the app, and widening every string with letter-spacing
// is either too small to clear macOS's narrow fallback (0.25px per character
// left the line at ~259px against a 260px cap) or large enough to red chrome
// that is not broken.
async function applyFace(page, family) {
  await page.addStyleTag({
    content: `*, *::before, *::after { font-family: ${family} !important; }`,
  });
}

// Same stress the navbar_layout spec applies: surface the balance and the entry
// badge at their widest realistic values so the row is measured full, not in
// whatever state the seed happens to leave it.
async function exposeStressControls(page) {
  await page.evaluate(() => {
    const badge = document.querySelector("[data-free-entry-badge]");
    if (badge) {
      badge.classList.remove("hidden");
      badge.dataset.tokenCount = "1";
    }
    const balance = document.querySelector("[data-balance-display]");
    if (balance) {
      balance.classList.remove("hidden");
      balance.textContent = "$1504";
    }
    // The balance slot's other face: a seeded $0-with-token user renders the
    // "✨ Free Entry" label ACTIVE instead of the amount. Stand it down so the
    // stress state is exactly one face — the widest amount — not both at once.
    const feLabel = document.querySelector("[data-free-entry-label]");
    if (feLabel) feLabel.classList.remove("is-active");
  });
}

async function documentMetrics(page) {
  return await page.evaluate(() => {
    const viewportWidth = document.documentElement.clientWidth;
    const documentWidth = Math.max(
      document.documentElement.scrollWidth,
      document.body.scrollWidth
    );
    // Anything whose own box, or whose unclipped text, reaches past the right
    // edge. The 4px regression came from a TEXT rect, not an element rect — the
    // tooltip's box stayed inside while its unbreakable line did not — so an
    // element-only sweep would have reported nothing to look at.
    //
    // "UNCLIPPED" MEANS BY ANY ANCESTOR, NOT JUST THE IMMEDIATE PARENT. This
    // used to read `getComputedStyle(node.parentElement).overflowX`, which is
    // the same question asked one level up and no further — and that was
    // sufficient only for as long as no page this spec measures contained a
    // horizontal scroller. /contests now leads with one (the featured contest
    // rail), and every card to the right of the fold reported its slate name,
    // its entry fee and its prize line as spilling. None of them do: they sit
    // inside `overflow-x: auto` and are reachable by scrolling THAT box, which
    // is why `documentOverflow` stayed at 0 through the same run while this
    // list filled up. A text node under a clipping ancestor cannot give the
    // DOCUMENT a scrollbar, which is the property this whole spec is about.
    //
    // The walk STOPS AT documentElement rather than including it: `overflow-x`
    // on <html> is a page-wide setting, and treating it as a clip would empty
    // this sweep for every node at once. `scanned` below is what keeps that
    // honest — a sweep that measured nothing must not read as a sweep that
    // found nothing.
    const clippedHorizontally = (el) => {
      for (let n = el; n && n !== document.documentElement; n = n.parentElement) {
        if (getComputedStyle(n).overflowX !== "visible") return true;
      }
      return false;
    };

    const spilling = [];
    let scanned = 0;
    const walker = document.createTreeWalker(document.body, NodeFilter.SHOW_TEXT);
    for (let node = walker.nextNode(); node; node = walker.nextNode()) {
      if (!node.nodeValue.trim()) continue;
      const parent = node.parentElement;
      if (!parent || clippedHorizontally(parent)) continue;
      scanned += 1;
      const range = document.createRange();
      range.selectNodeContents(node);
      for (const rect of range.getClientRects()) {
        if (rect.width > 0 && rect.right > viewportWidth + 1) {
          spilling.push({
            text: node.nodeValue.trim().slice(0, 40),
            right: Math.round(rect.right * 100) / 100,
          });
        }
      }
    }
    // The mechanism, measured directly: a tooltip whose line cannot fit its own
    // cap. This is what the host's white-space rule repairs, and unlike the
    // document overflow it does not depend on which face the runner painted.
    const tooltips = [...document.querySelectorAll("[data-studio-banner-tooltip]")].map(
      (tip) => ({
        text: (tip.textContent || "").trim().slice(0, 40),
        clientWidth: tip.clientWidth,
        scrollWidth: tip.scrollWidth,
        overflow: tip.scrollWidth - tip.clientWidth,
      })
    );

    return {
      viewportWidth,
      documentOverflow: documentWidth - viewportWidth,
      scanned,
      spilling: spilling.slice(0, 5),
      tooltips,
    };
  });
}

test("the vendored Montserrat is served by this app, same-origin, as real woff2", async ({
  page,
  baseURL,
}) => {
  await page.goto("/signin");

  // Both the preload and the two @font-face src URLs — the preload alone would
  // miss latin-ext, which no page preloads and every accented roster name needs.
  const urls = await page.evaluate(() => {
    const found = new Set();
    document
      .querySelectorAll('link[rel="preload"][as="font"]')
      .forEach((link) => found.add(link.href));
    document.querySelectorAll("style").forEach((style) => {
      const matches = style.textContent.match(/url\(['"]?([^'")]+\.woff2)['"]?\)/g) || [];
      matches.forEach((match) =>
        found.add(new URL(match.replace(/^url\(['"]?|['"]?\)$/g, ""), document.baseURI).href)
      );
    });
    return [...found];
  });

  expect(urls.length, "the head must declare the vendored woff2 faces").toBeGreaterThanOrEqual(2);

  const origin = new URL(baseURL).origin;
  for (const url of urls) {
    expect(new URL(url).origin, `${url} must be served by this app, not a CDN`).toBe(origin);

    const response = await page.request.get(url);
    expect(response.status(), `${url} must resolve through turf's own pipeline`).toBe(200);
    expect(
      (response.headers()["content-type"] || "").toLowerCase(),
      `${url} must be served as a font`
    ).toContain("woff2");
    // The gem ships 35508 and 68224 bytes; anything tiny is an error page with
    // a 200 on it, which is the failure a status check alone would wave through.
    expect((await response.body()).length, `${url} must carry real font bytes`).toBeGreaterThan(
      10000
    );
  }

  // The preconnects and the stylesheet link are gone: no page here may reach
  // Google for a face. This is the half of the property that a 200 cannot show.
  const html = await page.content();
  expect(html).not.toContain("fonts.googleapis.com");
  expect(html).not.toContain("fonts.gstatic.com");
});

test("the logged-in header stays contained when the page paints in a fallback face", async ({
  page,
}) => {
  await page.setViewportSize(VIEWPORTS[0]);
  await login(page, "alex@mcritchie.studio", "password");

  for (const viewport of VIEWPORTS) {
    await page.setViewportSize(viewport);
    await page.goto("/contests");
    await expect(page.locator("[data-username-display]").first()).toBeVisible();
    await exposeStressControls(page);

    // BOTH faces get measured, and the pair is the point. "as rendered" is
    // whatever this runner painted — Montserrat on a warm cache, where the
    // tooltip's line measured 263px against its 260px cap before the fix, so the
    // mechanism assertion bites even on a machine whose fallback is too narrow
    // to move the document. "fallback" is the state `font-display: optional`
    // actually produces on a cold cache, forced rather than waited for, which is
    // where the wide Linux face turns those 3px into a scrollbar.
    for (const face of ["as rendered", "fallback"]) {
      if (face === "fallback") await applyFace(page, FALLBACK_STACK);

      const metrics = await documentMetrics(page);
      const message = `${viewport.width}px, ${face}: ${JSON.stringify(metrics, null, 2)}`;

      // The symptom: no face the browser may legitimately paint in is allowed to
      // give this page a horizontal scrollbar.
      expect(metrics.documentOverflow, message).toBeLessThanOrEqual(1);
      // An empty `spilling` is only evidence if the sweep actually read
      // something. Without this, any future rule that clips the whole page
      // (an `overflow-x` on a wrapper near the root) turns this assertion
      // green by measuring nothing at all.
      expect(
        metrics.scanned,
        `${message}\nthe spill sweep measured no text — it cannot report a clean page`
      ).toBeGreaterThan(0);
      expect(metrics.spilling, message).toEqual([]);

      // The mechanism: every banner tooltip fits the cap it declares.
      expect(
        metrics.tooltips.length,
        `${message}\nno banner tooltip rendered — nothing was measured`
      ).toBeGreaterThan(0);
      for (const tip of metrics.tooltips) {
        expect(tip.overflow, message).toBeLessThanOrEqual(1);
      }
    }
  }
});
