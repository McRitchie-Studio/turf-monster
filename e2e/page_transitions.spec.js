const { test, expect } = require("@playwright/test");
const { login, loginAdmin, reseed, setupPhantomMock } = require("./helpers");

// [e2e] Turf's page transition with motion ON (config.page_transition_direction = :right,
// the gem's docs/PAGE_TRANSITIONS.md, /tasks/turf-adopts-page-transitions).
//
// THE LANE RUNS UNDER REDUCED MOTION, so this file opts out through contextOptions, the
// spelling that reaches the page. A bare `test.use({ reducedMotion })` is silently ignored
// (playwright.config.js and e2e/reduced_motion.spec.js). The last describe turns it back on.
//
// TWO PATHS TO ONE LOOK. Between two pages that are not signing pages the move is a Turbo view
// transition. A signing page (SigningCsp::PAGES: the contest page, the live board, /wallet,
// /account, contest create) must stay its own document under the strict policy, so it is entered
// and left by a full load, and the move there is the browser's cross-document view transition
// (engine 0.125.0, the gem's "Full page loads"). "Money pages" below proves that path on real
// signing pages. The new document draws that motion, so its recorder logs to sessionStorage,
// which outlives each document. No Turbo render runs on a signing page, so its turbo:load is
// not delayed.
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
// Engine 0.125.0 marks every visit "still" from turbo:visit to turbo:before-render, so a response
// Turbo will not render draws nothing. That mark is not a move, so these specs read past it.
const drawnStyles = (page) => page.evaluate(() => window.__styles.filter((style) => style !== "still"));
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
    expect(await drawnStyles(page)).toEqual(["fade-right"]);
  });

  test("a change of path draws the unfold, moving right", async ({ page }) => {
    await open(page, LOBBY, 0.99);
    await visit(page, HELP);
    const names = await seen(page);
    expect(names).toContain(`::view-transition-old(root) ${OUT}`);
    expect(names).toContain(`::view-transition-new(root) ${UNFOLD_IN}`);
    expect(await drawnStyles(page)).toEqual(["unfold-left"]);
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

// A log that outlives each document, so one spec reads both sides of a full load: each root
// motion, each held group that moved, and each policy violation. __random fixes the style the
// leaving page draws at pageswap, and only for the pick.
async function recordAcrossLoads(page, random = 0) {
  await page.addInitScript((value) => {
    const log = (line) => {
      const lines = JSON.parse(sessionStorage.getItem("pt-log") || "[]");
      lines.push(line);
      sessionStorage.setItem("pt-log", JSON.stringify(lines));
    };
    window.addEventListener("pageswap", (event) => {
      const real = Math.random;
      Math.random = () => value;
      setTimeout(() => { Math.random = real; }, 0);
      log(`pageswap ${event.viewTransition ? "transition" : "plain"}`);
    }, { capture: true });
    window.addEventListener("pagereveal", (event) => {
      window.__revealed = true;
      log(`pagereveal ${event.viewTransition ? "transition" : "plain"}`);
    });
    document.addEventListener("securitypolicyviolation", (event) => {
      log(`violation ${event.disposition} ${event.effectiveDirective} ${event.blockedURI} ${(event.sample || "").slice(0, 80)}`);
    });
    const seen = new Set();
    const tick = () => {
      for (const animation of document.getAnimations()) {
        const pseudo = animation.effect && animation.effect.pseudoElement;
        if (!pseudo || !pseudo.startsWith("::view-transition")) continue;
        const key = `${pseudo} ${animation.animationName || ""}`;
        if (!seen.has(key)) { seen.add(key); log(key); }
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }, random);
}

const logged = (page) => page.evaluate(() => JSON.parse(sessionStorage.getItem("pt-log") || "[]"));
const clearLog = (page) => page.evaluate(() => sessionStorage.removeItem("pt-log"));
const rootMotion = (lines) => lines.filter((line) => /-(old|new)\(root\) /.test(line)).sort();
const violations = (lines) => lines.filter((line) => line.startsWith("violation"));
const ONE_FADE = [`::view-transition-new(root) ${FADE_IN}`, `::view-transition-old(root) ${OUT}`];

// Turbo flips the URL before a reload answers, so the URL proves nothing here. The mark lives on
// the document, and only a new document has none. Past the whole motion when this returns.
// pagereveal comes at the first render, and a busy machine can finish the load event before it,
// so "complete" alone can read a page whose motion has not started.
const markDocument = (page) => page.evaluate(() => { window.__documentMark = true; });
async function landed(page, path) {
  await page.waitForFunction((target) => !window.__documentMark && window.__revealed && window.location.pathname === target
    && document.readyState === "complete"
    && document.documentElement.dataset.pageTransition === undefined
    && !document.getAnimations().some((a) => (a.effect?.pseudoElement || "").startsWith("::view-transition")), path);
}

async function leaveBy(page, link, path) {
  await markDocument(page);
  await clearLog(page);
  await link.click();
  await landed(page, path);
  return logged(page);
}

async function back(page, path) {
  await markDocument(page);
  await clearLog(page);
  await page.goBack();
  await landed(page, path);
  return logged(page);
}

// A real link in the page, for the pages that have none to the place a spec goes.
function linkTo(page, href) {
  return page.evaluate((target) => {
    const link = document.createElement("a");
    link.href = target;
    link.textContent = "go";
    link.setAttribute("data-test", "pt-full");
    link.style.cssText = "position:fixed;left:0;bottom:0;z-index:99999";
    document.body.appendChild(link);
  }, href).then(() => page.locator('[data-test="pt-full"]'));
}

async function openLobby(page, random = 0) {
  await recordAcrossLoads(page, random);
  await page.goto(LOBBY);
  await page.waitForFunction(() => window.Turbo && document.documentElement.dataset.pageTransitionDirection);
}

const contestLink = (page) => page.locator(`a[href="${CONTEST}"]`).first();

// A signing page stays a document of its own, and the full-load path is how it moves. The cart's
// own motion-on twin is in e2e/cart_survives_turbo_restore.spec.js.
test.describe("money pages", () => {
  // Alex McRitchie's report: "It works on most but for some reason not when I click the contest."
  test("clicking a contest in the lobby plays one move, lands on the contest page, and the board binds", async ({ page }) => {
    await openLobby(page);
    const lines = await leaveBy(page, contestLink(page), CONTEST);
    expect(rootMotion(lines), lines.join("\n")).toEqual(ONE_FADE);
    await expect(page.locator('meta[name="signing-csp"]')).toHaveCount(1);
    expect(lines.filter((line) => /group\(studio-header\) pt-/.test(line))).toEqual([]);

    const cards = page.locator('[x-data*="selectionBoard"] button[role="checkbox"]:not([disabled])');
    await cards.first().click();
    await expect(page.locator("body")).toContainText("1 / 6");
  });

  test("the same click can draw the unfold", async ({ page }) => {
    await openLobby(page, 0.99);
    const lines = await leaveBy(page, contestLink(page), CONTEST);
    expect(rootMotion(lines), lines.join("\n")).toEqual([`::view-transition-new(root) ${UNFOLD_IN}`, `::view-transition-old(root) ${OUT}`]);
  });

  test("leaving the contest page for a Turbo page plays one move", async ({ page }) => {
    await openLobby(page);
    await leaveBy(page, contestLink(page), CONTEST);
    const lines = await leaveBy(page, page.locator(`header a[href="${LOBBY}"]`).first(), LOBBY);
    expect(rootMotion(lines), lines.join("\n")).toEqual(ONE_FADE);
    await expect(page.locator('meta[name="signing-csp"]')).toHaveCount(0);
  });

  test("/wallet and /account play one move in and one move out", async ({ page }) => {
    await login(page, "mason@mcritchie.studio");
    const errors = [];
    page.on("pageerror", (error) => errors.push(error.message));
    await openLobby(page);
    for (const path of ["/wallet", "/account"]) {
      const into = await leaveBy(page, await linkTo(page, path), path);
      expect(rootMotion(into), `into ${path}\n${into.join("\n")}`).toEqual(ONE_FADE);
      await expect(page.locator('meta[name="signing-csp"]'), path).toHaveCount(1);
      await expect(page.locator("main"), path).toBeVisible();

      const out = await leaveBy(page, await linkTo(page, LOBBY), LOBBY);
      expect(rootMotion(out), `out of ${path}\n${out.join("\n")}`).toEqual(ONE_FADE);
    }
    expect(errors).toEqual([]);
  });

  // Playwright turns the back/forward cache off, so each Back here is a fresh back_forward load.
  // That is also what an ordinary session gets today: the session channel's message on the next
  // page's load evicts the page held in the cache. The restored page is the gem's unit test,
  // and the task's checks record a reading with no debugger attached.
  test("Back into a signing page and Back out of one each play one move", async ({ page }) => {
    await openLobby(page);
    await leaveBy(page, contestLink(page), CONTEST);
    const outOf = await back(page, LOBBY);
    expect(rootMotion(outOf), `Back out\n${outOf.join("\n")}`).toEqual(ONE_FADE);

    await leaveBy(page, contestLink(page), CONTEST);
    await leaveBy(page, page.locator(`header a[href="${LOBBY}"]`).first(), LOBBY);
    const intoSigning = await back(page, CONTEST);
    expect(rootMotion(intoSigning), `Back in\n${intoSigning.join("\n")}`).toEqual(ONE_FADE);
    await expect(page.locator('meta[name="signing-csp"]')).toHaveCount(1);
    expect(await page.evaluate(() => performance.getEntriesByType("navigation")[0].type)).toBe("back_forward");
    await expect(page.locator('[x-data*="selectionBoard"]').first()).toBeVisible();
  });

  test("a reload of a signing page plays nothing", async ({ page }) => {
    await openLobby(page);
    await leaveBy(page, contestLink(page), CONTEST);
    await markDocument(page);
    await clearLog(page);
    await page.reload();
    await landed(page, CONTEST);
    expect(rootMotion(await logged(page))).toEqual([]);
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

  // The strict policy on. The move must add no refused source: the sheet is 'self', and the
  // script takes the request's nonce. The solana-studio deep link is refused while its gem fix
  // is open (e2e/signing_csp.spec.js holds that), and nothing else may be.
  test.describe("under the enforced strict policy", () => {
    const pendingDeepLink = /\(function \(\) \{\s*var STATEMENT|window\.startPhantomDeepLink/;
    test.beforeEach(async ({ request }) => {
      const response = await request.post("/test/signing_csp", { form: { enforced: "true" } });
      expect(response.ok()).toBe(true);
    });
    test.afterEach(async ({ request }) => {
      await request.post("/test/signing_csp", { form: { enforced: "false" } });
    });

    test("a contest plays one move in and out, and Back, with no violation of its own", async ({ page }) => {
      await openLobby(page);
      const into = await leaveBy(page, contestLink(page), CONTEST);
      expect(rootMotion(into), into.join("\n")).toEqual(ONE_FADE);
      await page.waitForLoadState("networkidle");
      const out = await leaveBy(page, page.locator(`header a[href="${LOBBY}"]`).first(), LOBBY);
      expect(rootMotion(out), out.join("\n")).toEqual(ONE_FADE);
      const backIn = await back(page, CONTEST);
      expect(rootMotion(backIn), backIn.join("\n")).toEqual(ONE_FADE);
      await page.waitForLoadState("networkidle");
      const all = [...into, ...out, ...(await logged(page))];
      expect(violations(all).filter((line) => !pendingDeepLink.test(line))).toEqual([]);
    });

    test("/wallet and /account play one move with no violation of their own", async ({ page }) => {
      await login(page, "mason@mcritchie.studio");
      await openLobby(page);
      for (const path of ["/wallet", "/account"]) {
        const into = await leaveBy(page, await linkTo(page, path), path);
        expect(rootMotion(into), `into ${path}\n${into.join("\n")}`).toEqual(ONE_FADE);
        await page.waitForLoadState("networkidle");
        const settled = await logged(page);
        expect(violations(settled).filter((line) => !pendingDeepLink.test(line)), path).toEqual([]);
        const out = await leaveBy(page, await linkTo(page, LOBBY), LOBBY);
        expect(rootMotion(out), `out of ${path}\n${out.join("\n")}`).toEqual(ONE_FADE);
      }
    });

    test("the live board and the cosign queue play one move with no violation of their own", async ({ page }) => {
      await loginAdmin(page);
      await openLobby(page);
      for (const path of [`${CONTEST}/live`, "/admin/pending_transactions"]) {
        const into = await leaveBy(page, await linkTo(page, path), path);
        expect(rootMotion(into), `into ${path}\n${into.join("\n")}`).toEqual(ONE_FADE);
        await expect(page.locator('meta[name="signing-csp"]'), path).toHaveCount(1);
        await page.waitForLoadState("networkidle");
        expect(violations(await logged(page)).filter((line) => !pendingDeepLink.test(line)), path).toEqual([]);
        const out = await leaveBy(page, await linkTo(page, LOBBY), LOBBY);
        expect(rootMotion(out), `out of ${path}\n${out.join("\n")}`).toEqual(ONE_FADE);
      }
    });

    // THE CONTROL: the policy is live on the page that just moved. A script with no nonce is refused.
    test("control: the page that moved does refuse a script with no nonce", async ({ page }) => {
      await openLobby(page);
      await leaveBy(page, contestLink(page), CONTEST);
      await page.evaluate(() => {
        const script = document.createElement("script");
        script.textContent = "window.__ran = true";
        document.head.appendChild(script);
      });
      expect(await page.evaluate(() => window.__ran)).toBeUndefined();
    });
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
    expect(await drawnStyles(page)).toEqual([]);
    expect(await page.evaluate(() => document.documentElement.dataset.pageTransition)).toBeUndefined();
    expect(await page.evaluate(() => window.__held)).toBe(true);
    // The hold is one tick. The engine's image pause (a cap of 500ms) has no part in it here.
    const gap = await page.evaluate(() => window.__renderedAt - window.__heldAt);
    expect(gap).toBeLessThan(300);
  });

  test("a click into a signing page is a plain load", async ({ page }) => {
    await recordAcrossLoads(page, 0);
    await page.goto(LOBBY);
    await page.waitForFunction(() => window.Turbo);
    const lines = await leaveBy(page, contestLink(page), CONTEST);
    expect(rootMotion(lines), lines.join("\n")).toEqual([]);
    await expect(page.locator('meta[name="signing-csp"]')).toHaveCount(1);
  });
});
