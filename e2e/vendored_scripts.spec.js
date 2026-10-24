const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// turf-vendors-cdn-scripts: the slate page's Chart.js (vendor/javascript) and
// SortableJS (studio-engine's vendored classic build) load from our own origin
// and actually run, and wallet_provider.js's lazy tweetnacl load injects an
// integrity-pinned script that the browser accepts. Each assertion is something
// only a live browser produces: a global a script defined, a chart instance on
// a canvas, a drag library attached to a list, the request log, and an injected
// element after a call.

const SLATE = "/slates/world-cup-2026-group-1";

test.beforeEach(async ({ request }) => await reseed(request));

test.describe("vendored slate scripts", () => {
  test("Chart.js and SortableJS load from our origin and run on the slate page", async ({ page, baseURL }) => {
    const requests = [];
    page.on("request", (request) => requests.push(request.url()));

    await loginAdmin(page);
    await page.goto(SLATE);
    await page.waitForLoadState("networkidle");

    // 1. Chart.js: the global, its version, and a live chart on the slate's canvas.
    await expect.poll(() => page.evaluate(() => typeof window.Chart)).toBe("function");
    expect(await page.evaluate(() => window.Chart.version)).toBe("4.4.7");
    await expect
      .poll(() => page.evaluate(() => !!window.Chart.getChart(document.getElementById("formulaCurvesChart"))))
      .toBe(true);

    // 2. SortableJS: the engine's classic build defines the global, and
    // rankManager attached an instance to the rank list on Alpine init.
    expect(await page.evaluate(() => typeof window.Sortable)).toBe("function");
    await expect
      .poll(() =>
        page.evaluate(() => {
          const list = document.querySelector('[x-ref="sortableList"]');
          return !!(list && window.Sortable.get(list));
        })
      )
      .toBe(true);

    // 3. The request census: nothing from jsDelivr for either library, and both
    // fetched from this page's own origin under /assets/.
    const origin = new URL(baseURL || page.url()).origin;
    expect(requests.filter((url) => /cdn\.jsdelivr\.net\/npm\/(chart\.js|sortablejs)@/.test(url))).toEqual([]);
    const own = (pattern) => requests.filter((url) => url.startsWith(`${origin}/assets/`) && pattern.test(url));
    expect(own(/\/assets\/chart\.umd\.min-[0-9a-f]+\.js$/)).toHaveLength(1);
    expect(own(/\/assets\/studio\/sortable-[0-9a-f]+\.js$/)).toHaveLength(1);
  });

  test("the keypair provider's lazy tweetnacl load is integrity-pinned and the browser runs it", async ({ page }) => {
    await loginAdmin(page);
    await page.goto(SLATE);
    await page.waitForLoadState("networkidle");

    // The layout loads tweetnacl in the head, so the lazy branch runs only once
    // nacl is gone and a keypair secret is set: arrange exactly that, then
    // connect through the public registry.
    const result = await page.evaluate(async () => {
      delete window.nacl;
      const before = typeof window.nacl;
      window.__WALLET_KEYPAIR_SECRET = new Uint8Array(64).fill(7);
      const provider = window.walletProvider.get("keypair");
      const connected = await provider.connect();
      const injected = [...document.querySelectorAll('script[src*="tweetnacl@1.0.3/nacl-fast.min.js"]')].pop();
      return {
        before,
        integrity: injected && injected.integrity,
        crossOrigin: injected && injected.crossOrigin,
        signDetached: typeof (window.nacl && window.nacl.sign && window.nacl.sign.detached),
        publicKeyLength: connected.publicKey.toBytes().length,
      };
    });

    expect(result.before).toBe("undefined");
    expect(result.integrity).toBe("sha384-05+sicyRJQ56XpL4U9HJ8YbtSzFDvAg7apPKOGV6A0JsAJKFM68jp5oLnUjG5mEp");
    expect(result.crossOrigin).toBe("anonymous");
    // The browser ran the script only because the pin matched the file.
    expect(result.signDetached).toBe("function");
    expect(result.publicKeyLength).toBe(32);
  });
});
