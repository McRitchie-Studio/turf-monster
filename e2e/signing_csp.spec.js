// The signing pages' script policy, in a browser (SigningCsp). Outside
// production the strict policy is report-only, so a blocked script still runs
// and the browser fires securitypolicyviolation for it; this spec collects
// every one and expects none, apart from the gem-rendered items named below.
//
// PENDING lists inline script and handlers a gem still renders without the
// nonce, by the sample a report quotes ('report-sample'). Each entry names
// what clears it; drop the entry when the lock takes that release.
const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");
const { setupPhantomMock } = require("./phantom-mock");

const CONTEST = "/contests/world-cup-2026";

const PENDING = [
  // studio-engine studio/banners/_button: hover styles in inline handlers.
  { directive: "script-src-attr", sample: /^this\.style\./ },
  // solana-studio solana_studio/_phantom_deeplink: an un-nonced <script>.
  { directive: "script-src-elem", sample: /^\s*\(function \(\) \{\s*var STATEMENT/ },
  // studio-engine solana_sessions/phantom_callback: an un-nonced <script>.
  { directive: "script-src-elem", sample: /^\(function\(\) \{\s*var logEl = /, path: "/auth/phantom/callback" }
];

function pending(violation, path) {
  return PENDING.some((item) =>
    violation.directive.startsWith(item.directive) && item.sample.test(violation.sample) && (!item.path || item.path === path));
}

async function watchViolations(page) {
  await page.addInitScript(() => {
    window.__cspViolations = [];
    document.addEventListener("securitypolicyviolation", (event) => {
      window.__cspViolations.push({
        directive: event.effectiveDirective,
        blocked: event.blockedURI,
        sample: event.sample,
        disposition: event.disposition
      });
    });
  });
}

async function violationsOn(page, path) {
  await page.goto(path);
  await page.waitForLoadState("load");
  return page.evaluate(() => window.__cspViolations);
}

test.beforeEach(async ({ request }) => await reseed(request));

test("a guest on the contest page meets no script violation", async ({ page }) => {
  await watchViolations(page);
  const seen = await violationsOn(page, CONTEST);
  expect(seen.filter((v) => !pending(v, CONTEST))).toEqual([]);
});

test("an admin meets no script violation on any signing page", async ({ page }) => {
  await setupPhantomMock(page);
  await loginAdmin(page);
  await watchViolations(page);
  for (const path of [CONTEST, `${CONTEST}/edit`, "/contests/new", "/contests/generator", "/account",
                      "/admin/pending_transactions", "/auth/phantom/callback"]) {
    const seen = await violationsOn(page, path);
    expect(seen.filter((v) => !pending(v, path)), path).toEqual([]);
  }
});

// A Turbo visit keeps the document, and so its policy and nonce, while the
// new page carries its own request's nonce. csp_nonce_carry hands the
// incoming scripts the document's nonce, so they run under the strict policy.
test("a Turbo visit between signing pages runs the new page's scripts", async ({ page }) => {
  await setupPhantomMock(page);
  await loginAdmin(page);
  await watchViolations(page);
  await page.goto(CONTEST);
  await page.waitForLoadState("load");
  const before = await page.evaluate(() => performance.getEntriesByType("navigation")[0].name);

  for (const path of ["/account", `${CONTEST}/edit`, "/admin/pending_transactions"]) {
    await page.evaluate((target) => window.Turbo.visit(target), path);
    await page.waitForURL(`**${path}`);
    await page.waitForFunction(() => document.readyState === "complete");
    const seen = await page.evaluate(() => window.__cspViolations);
    expect(seen.filter((v) => !pending(v, CONTEST)), path).toEqual([]);
  }
  const after = await page.evaluate(() => performance.getEntriesByType("navigation")[0].name);
  expect(after).toBe(before);
});
