const { test, expect } = require("@playwright/test");
const {
  login, loginAdmin, reseed, seedRailContests, clearRailContests, createActiveEntry, setQuestState, grantManagedWallet
} = require("./helpers");

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
  // A poll inside the page: waitForFunction would take the async predicate's
  // promise itself as a truthy answer.
  await page.evaluate(async () => {
    const { LAZY } = await import("turf_stimulus");
    const { application } = await import("studio/stimulus");
    const pending = () => [...document.querySelectorAll("[data-studio-controller]")]
      .flatMap((el) => el.getAttribute("data-studio-controller").split(/\s+/).filter(Boolean))
      .filter((id) => id in LAZY && !application.router.modulesByIdentifier.has(id));
    for (let tries = 0; pending().length && tries < 100; tries++) await new Promise((r) => setTimeout(r, 50));
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
    window.__turboLoaded = false;
    document.addEventListener("turbo:load", () => (window.__turboLoaded = true), { once: true });
  });
  await page.evaluate((p) => window.Turbo.visit(p), path);
  // turbo:load in this document, or a full load (a signing page), which drops
  // the flag along with the document.
  await page.waitForFunction(() => window.__turboLoaded === true || window.__sameDocument !== true);
  await page.waitForLoadState("load");
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

async function check(page, path, options = {}) {
  return test.step(path, () => checkPage(page, path, options));
}

// The vault pages read the vault account over Solana RPC as they render. CI
// points SOLANA_RPC_URL at a dead port, so there they answer an error page with
// no import map; locally (devnet) they render. A page listed here may be
// unrendered, and its controllers are then excused from the coverage check
// below; any other page that fails to render fails the spec.
const RPC_PAGES = { "/admin/vault_state": ["vault-console"], "/admin/vault_init": ["vault-console"] };
const unrendered = new Set();

async function checkPage(page, path, { from = "/help" } = {}) {
  const response = await page.goto(path);
  await page.waitForLoadState("load");
  const rendered = response.ok() && await page.evaluate(() => {
    const map = document.querySelector('script[type="importmap"]');
    return !!map && "turf_stimulus" in JSON.parse(map.textContent).imports;
  });
  if (!rendered) {
    expect(Object.keys(RPC_PAGES), `${path} did not render the app (HTTP ${response.status()})`).toContain(path);
    RPC_PAGES[path].forEach((id) => unrendered.add(id));
    return null;
  }
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

// Each spec walks several pages, a full load and a Turbo visit apiece.
test.describe.configure({ mode: "serial", timeout: 180_000 });

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
    // Not yet age verified: the API keys card waits on the age gate (frame-reload).
    await check(page, "/account");

    // Age verified (the API keys form), a managed wallet (the withdraw card),
    // and an entry on the quest's invite step (the share invite and the poll).
    expect((await page.request.post("/test/set_age_verified", { data: { verified: true } })).ok()).toBe(true);
    await grantManagedWallet(page);
    await createActiveEntry(page, "e2e-rail-1", 0);
    await setQuestState(page, { username_changed: true, chat_sent: true, subscribed: true });
    for (const path of ["/account", "/wallet", "/contests/e2e-rail-1"]) await check(page, path);

    // A created key: the frame comes back with reveal-follow-up, connected in
    // place, still once.
    await page.goto("/account");
    const card = page.locator("turbo-frame#api_keys_card");
    await card.getByLabel("Name").fill("One application");
    await card.getByRole("button", { name: "Create key" }).click();
    await expect(card.locator("[data-api-key-secret]")).toBeVisible();
    const created = await census(page);
    expect(created.pairs.filter((p) => p.live !== 1), "a controller in the returned frame connected other than once").toEqual([]);
    created.pairs.forEach((p) => seen.add(p.id));
  } finally {
    await clearRailContests(page);
  }
});

test("admin pages: one application, each controller connected once", async ({ page }) => {
  await seedRailContests(page, 1, { upcoming: true });
  try {
    await loginAdmin(page);
    for (const path of ["/admin/schema", "/admin/dashboard", "/admin/hub", "/admin/navbar", "/admin/scoring",
                        "/admin/drop_signups/announcement", "/seeds_lab", "/toast_test", "/admin/authorities",
                        "/admin/vault_state", "/admin/vault_init", "/admin/pending_transactions", "/wallet", "/contests/e2e-rail-1"]) {
      await check(page, path, { from: "/admin/hub" });
    }
  } finally {
    await clearRailContests(page);
  }
});

// auto-submit posts its form the moment it connects, which would take the page
// away before it could be read. requestSubmit is replaced, in this page only,
// by a counter, so the page stays and the count is one more proof: one submit
// per arrival, on the full load and on the Turbo visit.
test("the unsubscribe page: auto-submit connects, and submits, once", async ({ page }) => {
  const res = await page.request.post("/test/seed_drop_signups", { data: { emails: [ `one-app-${Date.now()}@example.com` ] } });
  expect(res.ok()).toBe(true);
  const [ token ] = (await res.json()).unsubscribe_tokens;
  await page.addInitScript(() => {
    window.__submits = 0;
    HTMLFormElement.prototype.requestSubmit = function () { window.__submits += 1; };
  });

  const path = `/drop-signups/unsubscribe/${token}`;
  await check(page, path);
  expect(await page.evaluate(() => window.__submits), "a Turbo visit into the page submitted other than once").toBe(1);

  await page.goto(path);
  await page.waitForLoadState("load");
  expect(await page.evaluate(() => window.__submits), "a full load submitted other than once").toBe(1);
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
  const excused = [...unrendered].filter((id) => !seen.has(id));
  if (excused.length) console.log(`[one-application] not rendered without Solana RPC: ${excused.join(", ")}`);
  expect(registry.filter((id) => !seen.has(id) && !unseeded.includes(id) && !excused.includes(id))).toEqual([]);
});
