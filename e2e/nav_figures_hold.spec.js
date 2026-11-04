const { test, expect } = require("@playwright/test");
const { login, grantManagedWallet, reseed, loginAdmin } = require("./helpers");

// [e2e] The navbar's figures hold across a page change (/tasks/turf-adopts-page-transitions).
// Alex McRitchie: "the balance hides and flashes back. I'm cool with a fresh load but no need to
// flash the numbers, just have it change when there is a change in state."
//
// EVERY FRAME. An init script reads the pill, the seeds bar and the spinner on each animation
// frame and logs to sessionStorage, which outlives a full load. A frame with no pill element has
// no navbar to flash, so only a frame with one counts. The test env's cache is a null store, so
// each render here is the cold render, and the figure can only come from what the page remembers.
test.beforeEach(async ({ request }) => await reseed(request));

const LOBBY = "/contests";
const HELP = "/help";
const CONTEST = "/contests/world-cup-2026";

async function recordFrames(page) {
  await page.addInitScript(() => {
    const line = (entry) => {
      const lines = JSON.parse(sessionStorage.getItem("nav-frames") || "[]");
      lines.push(entry);
      sessionStorage.setItem("nav-frames", JSON.stringify(lines));
    };
    // pagereveal comes straight before a load's first render: the figure must be there already.
    window.addEventListener("pagereveal", () => {
      const pill = document.querySelector("header [data-balance-display]");
      line({ reveal: location.pathname, amount: pill ? pill.textContent.trim() : null });
    });
    let last = "";
    const read = () => {
      const pill = document.querySelector("header [data-balance-display]");
      if (pill) {
        const bar = document.querySelector("[data-nav-seeds-row] .seeds-bar-continuous");
        const level = document.querySelector("[data-nav-seeds-row] [data-seeds-level]");
        const spinner = document.querySelector(".nav-spinner-icon");
        const frame = {
          amount: pill.textContent.trim(),
          shown: !pill.classList.contains("hidden"),
          progress: bar ? Math.round(parseFloat(getComputedStyle(bar).getPropertyValue("--bar-progress")) || 0) : null,
          segments: bar ? bar.children.length : 0,
          level: level ? level.textContent.trim() : null,
          spinning: !!spinner && parseFloat(spinner.style.opacity || "0") > 0,
          free: !!document.querySelector("header [data-free-entry-label].is-active"),
          badge: !!document.querySelector("[data-free-entry-badge]:not(.hidden)"),
        };
        const key = JSON.stringify(frame);
        if (key !== last) { last = key; line({ path: location.pathname, ...frame }); }
      }
      requestAnimationFrame(read);
    };
    requestAnimationFrame(read);
  });
}

const logged = (page) => page.evaluate(() => JSON.parse(sessionStorage.getItem("nav-frames") || "[]"));
const frames = async (page) => (await logged(page)).filter((line) => !line.reveal);
const reveals = async (page) => (await logged(page)).filter((line) => line.reveal);
const clearFrames = (page) => page.evaluate(() => sessionStorage.removeItem("nav-frames"));

function answerRefresh(page, read) {
  return page.route("**/account/session_refresh", (route) => read(route));
}
const figures = (usdc, { seeds = 460, tokens = 0 } = {}) => ({
  status: 200,
  contentType: "application/json",
  body: JSON.stringify({ usdc, usdt: "0", sol: "1", tokens, seeds, level: 5, toward_next: 60, progress: 60, seeds_read: true, level_up_token_pending: false }),
});

async function signIn(page, email) {
  await login(page, email);
  await grantManagedWallet(page);
}

const pill = (page) => page.locator("header [data-balance-display]");

// The first page of a session: its normal loading state, then the figure.
async function firstFigure(page, text) {
  await page.goto(LOBBY);
  await expect(pill(page)).toHaveText(text);
  // The first read of a session may show its spinner: wait it out, so the walk starts at rest.
  await page.waitForFunction(() => parseFloat(document.querySelector(".nav-spinner-icon")?.style.opacity || "0") === 0);
  // The first figure of a session fills the bar once, over 1.2s: also before the walk.
  await page.waitForFunction(() => {
    const bar = document.querySelector("[data-nav-seeds-row] .seeds-bar-continuous");
    return bar && Math.round(parseFloat(getComputedStyle(bar).getPropertyValue("--bar-progress"))) === 60;
  });
  await page.waitForFunction(() => !document.getAnimations().some((a) => (a.effect?.pseudoElement || "").startsWith("::view-transition")));
}

async function clickLink(page, href) {
  await page.evaluate(() => { window.__documentMark = true; });
  await page.evaluate((target) => {
    const link = document.createElement("a");
    link.href = target;
    link.textContent = "go";
    link.setAttribute("data-test", "nav-go");
    link.style.cssText = "position:fixed;left:0;bottom:0;z-index:99999";
    document.body.appendChild(link);
  }, href);
  await page.locator('[data-test="nav-go"]').click();
  await page.waitForURL((u) => u.pathname === href);
}

// Past the move and past the fresh read.
async function settled(page, { fullLoad = false } = {}) {
  if (fullLoad) await page.waitForFunction(() => !window.__documentMark);
  const refreshed = page.waitForResponse("**/account/session_refresh").catch(() => null);
  await Promise.race([refreshed, page.waitForTimeout(3000)]);
  await page.waitForFunction(() => document.documentElement.dataset.pageTransition === undefined
    && !document.getAnimations().some((a) => (a.effect?.pseudoElement || "").startsWith("::view-transition")));
  await page.waitForTimeout(250);
}

function expectHeld(lines, amount) {
  expect(lines.length, "the recorder saw no navbar frame").toBeGreaterThan(0);
  const said = lines.map((f) => `${f.path} ${JSON.stringify(f)}`).join("\n");
  for (const frame of lines) {
    expect(frame.amount, `a frame with another figure\n${said}`).toBe(amount);
    expect(frame.shown, `a frame with the pill hidden\n${said}`).toBe(true);
    expect(frame.spinning, `a frame with the spinner showing\n${said}`).toBe(false);
    expect(frame.segments, `a frame with no seeds segments\n${said}`).toBe(5);
    expect(frame.progress, `a frame with the seeds bar moved\n${said}`).toBe(60);
    expect(frame.level, `a frame with another level\n${said}`).toBe("Level 5");
  }
}

async function walk(page) {
  await clearFrames(page);
  await clickLink(page, HELP);
  await settled(page);
  await clickLink(page, CONTEST);
  await settled(page, { fullLoad: true });
  await clickLink(page, LOBBY);
  await settled(page, { fullLoad: true });
  return logged(page);
}

function expectWalkHeld(lines, amount) {
  expectHeld(lines.filter((line) => !line.reveal), amount);
  // A full load has its figure before the first render, wherever the navbar has arrived by then.
  const arrivals = lines.filter((line) => line.reveal && line.amount !== null);
  expect(arrivals.map((line) => line.reveal)).toContain(CONTEST);
  for (const arrival of arrivals) expect(arrival.amount, JSON.stringify(arrival)).toBe(amount);
}

function heldSpecs() {
  test("every frame across a Turbo move and a full load keeps the figure, with no spinner", async ({ page }) => {
    await recordFrames(page);
    await signIn(page, "mason@mcritchie.studio");
    await answerRefresh(page, (route) => route.fulfill(figures("1024.00")));
    await firstFigure(page, "$1024");
    expectWalkHeld(await walk(page), "$1024");
  });
}

test.describe("with motion on", () => {
  test.use({ contextOptions: { reducedMotion: "no-preference" } });
  heldSpecs();

  // Carl's reading on the head before this: $222, then the snapshot's $111, then the live $333.
  test("Back overwrites the figure in the Turbo snapshot before it shows", async ({ page }) => {
    await recordFrames(page);
    await signIn(page, "mason@mcritchie.studio");
    let usdc = "111.00";
    await answerRefresh(page, (route) => route.fulfill(figures(usdc)));
    await firstFigure(page, "$111");

    usdc = "222.00";
    await clickLink(page, HELP);
    await expect(pill(page)).toHaveText("$222");
    await settled(page);

    usdc = "333.00";
    await clearFrames(page);
    await page.goBack();
    await expect(pill(page)).toHaveText("$333");
    const amounts = (await frames(page)).map((f) => f.amount);
    expect(amounts, JSON.stringify(amounts)).not.toContain("$111");
    expect(amounts).not.toContain("");
  });

  test("the warm render shows its figure with no memory, and the memory wins over it after", async ({ page }) => {
    await recordFrames(page);
    await signIn(page, "mason@mcritchie.studio");
    let usdc = "500.00";
    await answerRefresh(page, (route) => route.fulfill(figures(usdc)));
    expect((await page.request.post("/test/warm_balance", { data: { usdc: "500" } })).ok()).toBe(true);
    await clearFrames(page);
    await page.evaluate(() => sessionStorage.removeItem("tm:nav-figures"));
    await firstFigure(page, "$500");
    expect((await frames(page)).every((f) => f.amount === "$500" && f.shown), JSON.stringify(await frames(page))).toBe(true);

    // The cache still says $500 for up to 60 seconds. The read this tab just made says $600.
    usdc = "600.00";
    await page.reload();
    await expect(pill(page)).toHaveText("$600");
    await settled(page);
    await clearFrames(page);
    await clickLink(page, HELP);
    await settled(page);
    await clickLink(page, CONTEST);
    await settled(page, { fullLoad: true });
    const amounts = (await frames(page)).map((f) => f.amount);
    expect(amounts.length).toBeGreaterThan(0);
    expect([...new Set(amounts)], JSON.stringify(amounts)).toEqual(["$600"]);
  });

  test("the free-entry swap and the token badge hold across the walk", async ({ page }) => {
    await recordFrames(page);
    await signIn(page, "mason@mcritchie.studio");
    await answerRefresh(page, (route) => route.fulfill(figures("0", { tokens: 2 })));
    await page.goto(LOBBY);
    await expect(page.locator("header [data-free-entry-label].is-active")).toBeVisible();
    await page.waitForFunction(() => Math.round(parseFloat(getComputedStyle(document.querySelector("[data-nav-seeds-row] .seeds-bar-continuous")).getPropertyValue("--bar-progress"))) === 60);

    const lines = (await walk(page)).filter((line) => !line.reveal);
    expect(lines.length).toBeGreaterThan(0);
    for (const frame of lines) {
      expect(frame.free, JSON.stringify(lines)).toBe(true);
      expect(frame.badge, JSON.stringify(lines)).toBe(true);
      expect(frame.shown, JSON.stringify(lines)).toBe(false);
      expect(frame.amount, JSON.stringify(lines)).toBe("$0");
    }
  });

  test("a settling spend stays hidden across a move and Back, then shows the new figure", async ({ page }) => {
    await recordFrames(page);
    await signIn(page, "mason@mcritchie.studio");
    let usdc = "1024.00";
    await answerRefresh(page, (route) => route.fulfill(figures(usdc)));
    await firstFigure(page, "$1024");
    await clickLink(page, HELP);
    await settled(page);

    // The pre-spend read still answers during the window, as the RPC does.
    await clearFrames(page);
    await page.evaluate(() => { window.onchainSettled({ delayMs: 2500 }); });
    await expect(pill(page)).toBeHidden();
    await page.goBack();
    await page.waitForURL((u) => u.pathname === LOBBY);
    await page.waitForTimeout(800);
    const during = await frames(page);
    expect(during.filter((f) => f.path === LOBBY).map((f) => f.amount), JSON.stringify(during)).not.toContain("$1024");
    await expect(pill(page)).toBeHidden();

    usdc = "1000.00";
    await expect(pill(page)).toHaveText("$1000", { timeout: 15000 });
    await expect(pill(page)).toBeVisible();
  });

  test("a changed value updates, with no blank on the way", async ({ page }) => {
    await recordFrames(page);
    await signIn(page, "mason@mcritchie.studio");
    let usdc = "1024.00";
    await answerRefresh(page, (route) => route.fulfill(figures(usdc)));
    await firstFigure(page, "$1024");
    await clearFrames(page);

    usdc = "2048.00";
    await clickLink(page, HELP);
    await expect(pill(page)).toHaveText("$2048");
    const lines = await frames(page);
    expect(lines.every((f) => f.shown && f.amount !== ""), JSON.stringify(lines)).toBe(true);
    // The recorder logs a change, so a frame that still says the old figure logs nothing here.
    expect(lines.every((f) => ["$1024", "$2048"].includes(f.amount)), JSON.stringify(lines)).toBe(true);
    expect(lines[lines.length - 1].amount).toBe("$2048");

    await clearFrames(page);
    await clickLink(page, CONTEST);
    await settled(page, { fullLoad: true });
    expect((await frames(page)).every((f) => f.amount === "$2048" && f.shown)).toBe(true);
  });

  test("a failed fresh read keeps the last figure, and it stays while reads keep failing", async ({ page }) => {
    await recordFrames(page);
    await signIn(page, "mason@mcritchie.studio");
    let failing = false;
    await answerRefresh(page, (route) => (failing ? route.abort() : route.fulfill(figures("1024.00"))));
    await firstFigure(page, "$1024");

    failing = true;
    expectWalkHeld(await walk(page), "$1024");
  });

  test("a logout then a different user shows no old figure", async ({ page }) => {
    await recordFrames(page);
    await signIn(page, "mason@mcritchie.studio");
    let usdc = "1024.00";
    await answerRefresh(page, (route) => route.fulfill(figures(usdc)));
    await firstFigure(page, "$1024");

    await page.goto("/help");
    await page.evaluate(() => { document.querySelector('a[href="/logout"]').click(); });
    await page.waitForFunction(() => document.body && !document.body.dataset.userId);
    await clearFrames(page);

    usdc = "7.00";
    await signIn(page, `nav-figures-${Date.now()}@example.test`);
    await page.goto(LOBBY);
    await expect(pill(page)).toHaveText("$7");
    const lines = await frames(page);
    expect(lines.map((f) => f.amount), JSON.stringify(lines)).not.toContain("$1024");
  });

  test("a sign-in as a different user with no logout shows no old figure", async ({ page }) => {
    await recordFrames(page);
    await signIn(page, "mason@mcritchie.studio");
    let usdc = "1024.00";
    await answerRefresh(page, (route) => route.fulfill(figures(usdc)));
    await firstFigure(page, "$1024");

    usdc = "7.00";
    await page.context().clearCookies();
    await page.goto("/signin");
    await clearFrames(page);
    await signIn(page, `nav-figures-switch-${Date.now()}@example.test`);
    await page.goto(LOBBY);
    await expect(pill(page)).toHaveText("$7");
    expect((await frames(page)).map((f) => f.amount)).not.toContain("$1024");
  });

  test("Act as shows none of the admin's figure, and neither does the way back", async ({ page }) => {
    await recordFrames(page);
    await loginAdmin(page);
    await grantManagedWallet(page);
    let usdc = "1024.00";
    await answerRefresh(page, (route) => route.fulfill(figures(usdc)));
    await firstFigure(page, "$1024");

    usdc = "7.00";
    await page.goto("/admin/users");
    await clearFrames(page);
    page.on("dialog", (dialog) => dialog.accept());
    await page.getByRole("button", { name: "Act as" }).first().click();
    const out = page.getByRole("button", { name: /Return to/ });
    await expect(out).toBeVisible({ timeout: 20000 });
    await page.waitForTimeout(500);
    expect((await frames(page)).filter((f) => f.path !== "/admin/users").map((f) => f.amount)).not.toContain("$1024");
    await expect(pill(page)).toHaveText("$7");
  });
});

// The pills flashed with no motion too: the cause is the cold render, not the transition.
test.describe("with reduced motion", () => {
  test.use({ contextOptions: { reducedMotion: "reduce" } });
  heldSpecs();
});
