const { test, expect } = require("@playwright/test");
const { login, loginAdmin, reseed, seedRailContests, clearRailContests } = require("./helpers");

// [e2e] One Stimulus application per page, the engine's, and every controller
// on it connects once.
//
// Turf used to start a second application (Application.start() in
// turf_stimulus.js) beside the engine's studio/stimulus. It now registers its
// controllers on the engine's, and its markup names them with
// data-studio-controller. This spec visits a page for each of Turf's
// controllers and holds three things on each:
//
//   1. turf_stimulus exports the SAME application object studio/stimulus does;
//   2. no element carries Stimulus' default data-controller / data-action,
//      which nothing reads any more (a control that would never connect);
//   3. every (element, identifier) pair on the page has exactly one connected
//      controller: on the full load, and, counted connect by connect, across a
//      Turbo visit into the page (pages that are not signing pages; a signing
//      page is always a full load, so 3 holds on its load).
//
// The pages are the ones the four *_stimulus_pages specs press on, so between
// them every controller in turf_stimulus.js's registry is seen; the last spec
// checks that union against the registry itself.

const seen = new Set();

// Reads the page: the two applications, stray default attributes, and the
// controller count for each pair. Lazy controllers named on the page are
// waited for (they register on first sight).
async function census(page) {
  await page.waitForFunction(async () => {
    const { LAZY } = await import("turf_stimulus");
    const { application } = await import("studio/stimulus");
    const named = [...document.querySelectorAll("[data-studio-controller]")]
      .flatMap((el) => el.getAttribute("data-studio-controller").split(/\s+/).filter(Boolean));
    return named.filter((id) => id in LAZY).every((id) => application.router.modulesByIdentifier.has(id));
  });

  return page.evaluate(async () => {
    const turf = await import("turf_stimulus");
    const { application } = await import("studio/stimulus");
    const registered = application.router.modulesByIdentifier;
    const pairs = [];
    document.querySelectorAll("[data-studio-controller]").forEach((el) => {
      el.getAttribute("data-studio-controller").split(/\s+/).filter(Boolean).forEach((id) => {
        if (!registered.has(id)) return;
        const live = application.controllers.filter((c) => c.element === el && c.identifier === id).length;
        pairs.push({ id, live, tag: el.outerHTML.slice(0, 90) });
      });
    });
    return {
      same: turf.application === application,
      stray: document.querySelectorAll("[data-controller], [data-action]").length,
      pairs,
      turfIds: Object.keys(turf.LAZY)
    };
  });
}

// Counts every connect while Turbo visits `path` from the current page. The
// counter wraps the application's logDebugActivity, which each controller's
// context calls once per connect.
async function connectsAcrossTurboVisit(page, path) {
  await page.evaluate(async () => {
    const { application } = await import("studio/stimulus");
    document.querySelectorAll("[data-studio-controller]").forEach((el) => (el.__beforeVisit = true));
    window.__connects = [];
    const original = application.logDebugActivity;
    application.logDebugActivity = (identifier, name, detail) => {
      if (name === "connect") window.__connects.push({ identifier, element: detail && detail.element });
      return original(identifier, name, detail);
    };
    window.__sameDocument = true;
  });
  await page.evaluate((p) => window.Turbo.visit(p), path);
  await page.waitForFunction((p) => window.location.pathname === new URL(p, window.location.href).pathname &&
    !(window.Turbo.session.navigator.currentVisit && window.Turbo.session.navigator.currentVisit.state === "started"), path);
  return page.evaluate(async () => {
    const { application } = await import("studio/stimulus");
    const registered = application.router.modulesByIdentifier;
    const result = { sameDocument: window.__sameDocument === true, doubles: [], missing: [] };
    document.querySelectorAll("[data-studio-controller]").forEach((el) => {
      el.getAttribute("data-studio-controller").split(/\s+/).filter(Boolean).forEach((id) => {
        if (!registered.has(id)) return;
        const n = window.__connects.filter((c) => c.element === el && c.identifier === id).length;
        if (n > 1) result.doubles.push(`${id} x${n}`);
        // A data-turbo-permanent element survives the visit and need not reconnect.
        if (n === 0 && !el.__beforeVisit) result.missing.push(id);
      });
    });
    return result;
  });
}

const onSigningPage = (page) => page.evaluate(() => !!document.querySelector('meta[name="signing-csp"]'));

async function check(page, path, { from = "/help" } = {}) {
  await page.goto(path);
  await page.waitForLoadState("load");
  const first = await census(page);
  expect(first.same, "turf_stimulus registers on studio/stimulus' application").toBe(true);
  expect(first.stray, `${path}: an element still names a controller on data-controller/data-action`).toBe(0);
  expect(first.pairs.filter((p) => p.live !== 1), `${path}: a controller connected other than once`).toEqual([]);
  first.pairs.forEach((p) => seen.add(p.id));

  if (await onSigningPage(page)) return first;

  await page.goto(from);
  await page.waitForLoadState("load");
  if (await onSigningPage(page)) return first;
  const visit = await connectsAcrossTurboVisit(page, path);
  if (!visit.sameDocument) return first;
  expect(visit.doubles, `${path}: a Turbo visit connected a controller twice`).toEqual([]);
  expect(visit.missing, `${path}: a Turbo visit left a controller unconnected`).toEqual([]);
  return first;
}

test.describe.configure({ mode: "serial" });

test.beforeAll(async ({ request }) => await reseed(request));

test("visitor pages: one application, each controller connected once", async ({ page }) => {
  await seedRailContests(page, 1, { upcoming: true });
  try {
    for (const path of ["/help/how-to-play", "/teams", "/players", "/contract", "/proof-of-reserves", "/contests", "/contests/e2e-rail-1"]) {
      await check(page, path);
    }
  } finally {
    await clearRailContests(page);
  }
});

test("player pages: one application, each controller connected once", async ({ page }) => {
  await seedRailContests(page, 1, { upcoming: true });
  try {
    await login(page, `one-application-${Date.now()}@example.test`);
    for (const path of ["/account", "/wallet", "/contests/e2e-rail-1"]) await check(page, path);
  } finally {
    await clearRailContests(page);
  }
});

test("admin pages: one application, each controller connected once", async ({ page }) => {
  await loginAdmin(page);
  for (const path of ["/admin/schema", "/admin/dashboard", "/admin/hub", "/admin/navbar", "/admin/scoring",
                      "/admin/drop_signups/announcement", "/seeds_lab", "/toast_test", "/admin/authorities",
                      "/admin/vault_state", "/admin/pending_transactions", "/wallet"]) {
    await check(page, path, { from: "/admin/hub" });
  }
});

test("between them the pages connected every controller turf_stimulus registers", async ({ page }) => {
  await page.goto("/help");
  const registry = await page.evaluate(async () => {
    const turf = await import("turf_stimulus");
    const map = JSON.parse(document.querySelector('script[type="importmap"]').textContent).imports;
    const source = await (await fetch(map.turf_stimulus)).text();
    const statics = [...source.matchAll(/^application\.register\("([a-z-]+)"/gm)].map((m) => m[1]);
    return [...statics, ...Object.keys(turf.LAZY)];
  });
  // Rendered only with fixtures these pages do not seed: a cosign row needs a
  // pending transaction; the dev score tools need a dev-mode live contest.
  // e2e/signing_csp.spec.js and the live scoreboard specs press those.
  const unseeded = ["cosign-button", "dev-score-tools"];
  expect(registry.length).toBeGreaterThan(30);
  expect(registry.filter((id) => !seen.has(id) && !unseeded.includes(id))).toEqual([]);
});
