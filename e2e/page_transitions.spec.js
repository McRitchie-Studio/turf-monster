const { test, expect } = require("@playwright/test");
const { login, loginAdmin, reseed, setupPhantomMock } = require("./helpers");

// [e2e] Turf's page transition with motion ON (config.page_transition_direction = :right,
// the gem's docs/PAGE_TRANSITIONS.md, /tasks/turf-adopts-page-transitions).
//
// THE LANE RUNS UNDER REDUCED MOTION, so this file opts out through contextOptions, the
// spelling that reaches the page. A bare `test.use({ reducedMotion })` is silently ignored
// (playwright.config.js and e2e/reduced_motion.spec.js). The last describe turns it back on.
//
// WHERE MOTION PLAYS. Only between two pages that are not signing pages. A signing page
// (SigningCsp::PAGES: the contest page, the live board, /wallet, /account, contest create)
// is entered and left by a full load, so no Turbo render runs on either side of it, and its
// turbo:load does not move. "Money pages" below proves that, because it is why the 700ms
// delay of turbo:load cannot reach contest entry or wallet connect.
test.use({ contextOptions: { reducedMotion: "no-preference" } });

test.beforeEach(async ({ request }) => await reseed(request));

const LOBBY = "/contests";
const HELP = "/help";
const CONTEST = "/contests/world-cup-2026";
const OUT = "pt-out-right";
const FADE_IN = "pt-in-from-left";
const UNFOLD_IN = "pt-unfold-left";

// A recorder for what a browser played. Animation names exist only in getAnimations().
// __random fixes the style Math.random draws, and only for the pick: Turbo draws its history
// ids from Math.random too, and a constant would give every history entry one id.
async function record(page, random = 0) {
  await page.addInitScript((value) => {
    window.__random = value;
    window.addEventListener("turbo:before-render", () => {
      const real = Math.random;
      Math.random = () => window.__random;
      setTimeout(() => { Math.random = real; }, 0);
    }, { capture: true });
    window.__seen = [];
    window.__styles = [];
    window.__headerTops = [];
    window.__barTops = [];
    const top = (selector) => {
      const el = document.querySelector(selector);
      return el ? Math.round(el.getBoundingClientRect().top) : null;
    };
    const tick = () => {
      for (const animation of document.getAnimations()) {
        const pseudo = animation.effect && animation.effect.pseudoElement;
        if (!pseudo || !pseudo.startsWith("::view-transition")) continue;
        const key = `${pseudo} ${animation.animationName || ""}`;
        if (!window.__seen.includes(key)) window.__seen.push(key);
      }
      const style = document.documentElement.dataset.pageTransition;
      if (style) {
        if (!window.__styles.includes(style)) window.__styles.push(style);
        window.__headerTops.push(top("header.vt-pinned-header"));
        window.__barTops.push(top("[data-frozen-banner]"));
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }, random);
}

const seen = (page) => page.evaluate(() => window.__seen);
const pageMoves = (names) => names.filter((name) => /\(root\) pt-/.test(name));

function nextLoad(page) {
  return page.evaluate(() => new Promise((done) => document.addEventListener("turbo:load", done, { once: true })));
}

// A Turbo visit through a real link in the page, so nothing here is a full load.
async function visit(page, path) {
  const load = nextLoad(page);
  await page.evaluate((href) => {
    const link = document.createElement("a");
    link.href = href;
    link.textContent = "go";
    link.setAttribute("data-test", "pt-go");
    link.style.cssText = "position:fixed;left:0;bottom:0;z-index:99999";
    document.body.appendChild(link);
  }, path);
  await page.locator('[data-test="pt-go"]').click();
  await load;
}

async function open(page, path, random) {
  await record(page, random);
  await page.goto(path);
  await page.waitForFunction(() => window.Turbo && document.documentElement.dataset.pageTransitionDirection);
}

test.describe("what plays", () => {
  test("a change of path draws the fade, moving right", async ({ page }) => {
    await open(page, LOBBY, 0);
    await visit(page, HELP);
    const names = await seen(page);
    expect(names).toContain(`::view-transition-old(root) ${OUT}`);
    expect(names).toContain(`::view-transition-new(root) ${FADE_IN}`);
    expect(await page.evaluate(() => window.__styles)).toEqual(["fade-right"]);
  });

  test("a change of path draws the unfold, moving right", async ({ page }) => {
    await open(page, LOBBY, 0.99);
    await visit(page, HELP);
    const names = await seen(page);
    expect(names).toContain(`::view-transition-old(root) ${OUT}`);
    expect(names).toContain(`::view-transition-new(root) ${UNFOLD_IN}`);
    expect(await page.evaluate(() => window.__styles)).toEqual(["unfold-left"]);
  });

  test("Back and Forward play the same direction", async ({ page }) => {
    await open(page, LOBBY, 0);
    await visit(page, HELP);
    for (const travel of ["goBack", "goForward"]) {
      await page.evaluate(() => { window.__seen.length = 0; });
      const load = nextLoad(page);
      await page[travel]();
      await load;
      expect(await seen(page), travel).toContain(`::view-transition-old(root) ${OUT}`);
    }
  });

  test("a refresh of the same page plays nothing", async ({ page }) => {
    await open(page, LOBBY, 0);
    const load = nextLoad(page);
    await page.evaluate(() => window.Turbo.visit(window.location.href, { action: "replace" }));
    await load;
    expect(pageMoves(await seen(page))).toEqual([]);
    expect(await page.evaluate(() => window.__styles)).toEqual(["still"]);
  });

  test("a change of query only plays nothing", async ({ page }) => {
    await open(page, LOBBY, 0);
    const load = nextLoad(page);
    await page.evaluate(() => window.Turbo.visit(`${window.location.pathname}?pt=1`));
    await load;
    expect(pageMoves(await seen(page))).toEqual([]);
  });

  // The live board moves by Turbo Stream broadcasts, not by visits. A broadcast is what a
  // score does to the page, so this one delivers a stream the way the socket hands it over.
  test("a live board broadcast starts no transition", async ({ page }) => {
    await open(page, "/live", 0);
    await page.locator("#nfl_live_scoreboard").waitFor({ state: "attached" });
    const marker = await page.evaluate(async () => {
      window.Turbo.renderStreamMessage(
        '<turbo-stream action="append" target="nfl_live_scoreboard"><template><i id="pt-score"></i></template></turbo-stream>'
      );
      await new Promise((done) => setTimeout(done, 400));
      return !!document.getElementById("pt-score");
    });
    expect(marker).toBe(true);
    expect(await seen(page)).toEqual([]);
    expect(await page.evaluate(() => window.__styles)).toEqual([]);
  });
});

test.describe("what holds still", () => {
  test("the navbar group holds its place and the page moves under it", async ({ page }) => {
    await open(page, LOBBY, 0);
    await visit(page, HELP);
    const names = await seen(page);
    // Named groups the engine's rules do not move. The root is what moves.
    expect(names.filter((name) => /studio-header\) pt-/.test(name))).toEqual([]);
    const tops = await page.evaluate(() => window.__headerTops);
    expect(tops.length).toBeGreaterThan(0);
    expect(new Set(tops).size, `header tops: ${[...new Set(tops)]}`).toBe(1);
  });

  test("a scrolled page keeps its sticky header through a move and after it", async ({ page }) => {
    await open(page, LOBBY, 0);
    await page.evaluate(() => window.scrollTo(0, 300));
    await visit(page, HELP);
    const header = page.locator("header.vt-pinned-header");
    await expect(header).toHaveCount(1);
    // The swap lands at the top, under the environment bar. The new page must stick too.
    await page.evaluate(() => window.scrollTo(0, 400));
    await expect.poll(async () => (await header.boundingBox()).y).toBeLessThanOrEqual(1);
  });

  test("the frozen-account bar rides the pinned header through a move", async ({ page }) => {
    await login(page, "mason@mcritchie.studio");
    await page.request.post("/test/set_frozen", { data: { frozen: "true" } });
    try {
      await open(page, LOBBY, 0);
      await expect(page.locator("[data-frozen-banner]")).toBeVisible();
      await visit(page, HELP);
      const tops = await page.evaluate(() => window.__barTops);
      expect(tops.length).toBeGreaterThan(0);
      expect(new Set(tops).size, `bar tops: ${[...new Set(tops)]}`).toBe(1);
      await expect(page.locator("[data-frozen-banner]")).toBeVisible();
      await expect(page.locator("[data-frozen-banner]")).toHaveCount(1);
    } finally {
      await page.request.post("/test/set_frozen", { data: { frozen: "false" } });
    }
  });

  test("the impersonation bar survives a move and its way out still works", async ({ page }) => {
    await loginAdmin(page);
    await page.goto("/admin/users");
    page.on("dialog", (dialog) => dialog.accept());
    await page.getByRole("button", { name: "Act as" }).first().click();
    const out = page.getByRole("button", { name: /Return to/ });
    await expect(out).toBeVisible();

    await open(page, LOBBY, 0);
    await visit(page, HELP);
    await expect(out).toHaveCount(1);
    await expect(out).toBeVisible();

    await out.click();
    await expect(out).toHaveCount(0);
  });

  test("the gear sidebar opens and closes after a move, and a move shuts it", async ({ page }) => {
    await login(page, "mason@mcritchie.studio");
    await open(page, LOBBY, 0);
    await visit(page, HELP);

    const trigger = page.locator("[data-gear-sidebar-trigger]").first();
    await trigger.click();
    await expect(trigger).toHaveAttribute("aria-expanded", "true");
    await page.keyboard.press("Escape");
    await expect(trigger).toHaveAttribute("aria-expanded", "false");

    await trigger.click();
    await expect(trigger).toHaveAttribute("aria-expanded", "true");
    const load = nextLoad(page);
    await page.evaluate(() => window.Turbo.visit("/contests"));
    await load;
    await expect(trigger).toHaveAttribute("aria-expanded", "false");

    await trigger.click();
    await expect(trigger).toHaveAttribute("aria-expanded", "true");
  });
});

// A signing page is a document of its own, so a move never touches it. These hold that fact,
// and the journeys that lean on it. The cart's own motion-on twin is in
// e2e/cart_survives_turbo_restore.spec.js.
test.describe("money pages", () => {
  test("arriving at the contest page from a moving page is a full load, and the board binds", async ({ page }) => {
    await open(page, LOBBY, 0);
    await page.evaluate(() => { window.__documentMark = true; });
    await page.evaluate((href) => {
      const link = document.createElement("a");
      link.href = href;
      link.textContent = "go";
      link.setAttribute("data-test", "pt-go");
      link.style.cssText = "position:fixed;left:0;bottom:0;z-index:99999";
      document.body.appendChild(link);
    }, CONTEST);
    await page.locator('[data-test="pt-go"]').click();
    await page.waitForURL((u) => u.pathname === CONTEST);
    await page.waitForLoadState("networkidle");

    expect(await page.evaluate(() => window.__documentMark)).toBeUndefined();
    await expect(page.locator('meta[name="signing-csp"]')).toHaveCount(1);
    expect(pageMoves(await seen(page))).toEqual([]);

    const cards = page.locator('[x-data*="selectionBoard"] button[role="checkbox"]:not([disabled])');
    await cards.first().click();
    await expect(page.locator("body")).toContainText("1 / 6");
  });

  test("the wallet picker opens and finds the wallet on a page reached from a moving page", async ({ page }) => {
    await setupPhantomMock(page);
    await open(page, LOBBY, 0);
    await visit(page, "/signin");
    expect(pageMoves(await seen(page)).length).toBeGreaterThan(0);

    // /signin is a moving page, so the picker's script has to bind at the swap's far side.
    const age = page.locator('input[type="checkbox"]').first();
    if (await age.isVisible().catch(() => false)) await age.check();
    await page.locator('button:has-text("Solana")').click();
    const wallet = page.locator('button:has-text("phantom")').first();
    await wallet.waitFor({ state: "visible" });
    await wallet.click();
    await page.waitForURL((url) => !url.pathname.startsWith("/signin"));
    await expect(page.locator("#session-context")).toHaveCount(1);
    expect(await page.evaluate(() => JSON.parse(document.getElementById("session-context").textContent).loggedIn)).toBe(true);
  });

  test("/wallet and /account are their own documents and render for a signed-in player", async ({ page }) => {
    await login(page, "mason@mcritchie.studio");
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await open(page, LOBBY, 0);
    for (const path of ["/wallet", "/account"]) {
      await page.evaluate((href) => { window.Turbo.visit(href); }, path);
      await page.waitForURL((u) => u.pathname === path);
      await page.waitForLoadState("networkidle");
      await expect(page.locator('meta[name="signing-csp"]'), path).toHaveCount(1);
      await expect(page.locator("main"), path).toBeVisible();
      expect(pageMoves(await seen(page)), path).toEqual([]);
    }
    expect(errors).toEqual([]);
  });
});

test.describe("smooth load", () => {
  // Turf has no searching page: its Play now is a link to the contest page, a full load.
  test("the landing page's Play now reaches a working board", async ({ page }) => {
    await open(page, "/turf-monster-v2", 0);
    await page.evaluate(() => { window.__documentMark = true; });
    const play = page.locator('[data-test="v2-live"] a').first();
    await play.scrollIntoViewIfNeeded();
    await play.click();
    await page.waitForURL((u) => u.pathname.startsWith("/contests/"));
    await page.waitForLoadState("networkidle");
    expect(await page.evaluate(() => window.__documentMark)).toBeUndefined();
    await expect(page.locator('[x-data*="selectionBoard"]').first()).toBeVisible();
  });

  test("the funnel splash renders with a set direction", async ({ page }) => {
    // An admin may preview the seeded page whether or not it is live.
    await loginAdmin(page);
    await page.goto("/lp/tiktok");
    await expect(page.locator('meta[name="page-transition-direction"]')).toHaveAttribute("content", "right");
    await expect(page.locator(".lp-splash h1").first()).toBeVisible();
    await expect(page.locator('[data-test="funnel-how-it-works"]')).toBeVisible();
  });
});

test.describe("reduced motion", () => {
  test.use({ contextOptions: { reducedMotion: "reduce" } });

  test("nothing moves, and Turf's own one-tick hold still takes the render", async ({ page }) => {
    await page.addInitScript(() => {
      // On window in bubble, so it reads the event after every listener on document.
      window.addEventListener("turbo:before-render", (event) => {
        window.__held = event.defaultPrevented;
        window.__heldAt = performance.now();
      });
      window.addEventListener("turbo:render", () => { window.__renderedAt = performance.now(); });
    });
    await record(page, 0);
    await page.goto(LOBBY);
    await page.waitForFunction(() => window.Turbo);
    await visit(page, HELP);

    expect(await seen(page)).toEqual([]);
    expect(await page.evaluate(() => window.__styles)).toEqual([]);
    expect(await page.evaluate(() => document.documentElement.dataset.pageTransition)).toBeUndefined();
    expect(await page.evaluate(() => window.__held)).toBe(true);
    // The hold is one tick. The engine's image pause (a cap of 500ms) has no part in it here.
    const gap = await page.evaluate(() => window.__renderedAt - window.__heldAt);
    expect(gap).toBeLessThan(300);
  });
});
