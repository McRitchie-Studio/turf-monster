const { test, expect } = require("@playwright/test");
const { loginViaPhantom, reseed } = require("./helpers");
const { setupPhantomMock } = require("./phantom-mock");

// ONE HOLD, ONE ENTER REQUEST (task board-hold-enters-once).
//
// selectionBoard().init() listens on DOCUMENT for the hold button's
// hold-button:* events. Document outlives a Turbo visit, the component does
// not: every board Alpine builds (a fresh render, or the snapshot Turbo puts
// back on Back) runs init() again. A board that leaves its listener behind
// keeps answering holds from the page that replaced it, so one hold sends
// POST /contests/:slug/enter once per board the tab has ever built.
//
// This spec counts the requests that LEAVE THE BROWSER, at the route, because
// that is the only number the player's wallet cares about. The listener census
// beside it says why the number is what it is.
//
// CONTROL (run on 2026-10-09 against this desk): with the teardown removed from
// selectionBoard (destroy(), the turbo:before-cache hook and the previous-board
// sweep in init()), the first test reads 2 requests and 2 listeners.

const CONTEST_PATH = "/contests/world-cup-2026";

// The lane shares one database: clear throttles and cached session state
// before each login, as every spec that signs in does.
test.beforeEach(async ({ request }) => await reseed(request));

const json = (status, body) => ({ status, contentType: "application/json", body: JSON.stringify(body) });

// Count the listeners LIVE on window and document, by event type. Installed
// before any page script, and Turbo visits never reload the document, so the
// census spans the whole tab lifetime the bug needs.
async function censusListeners(page) {
  await page.addInitScript(() => {
    const live = new Map(); // "target:type" -> Set of callbacks
    window.__listenerCensus = (key) => (live.get(key) ? live.get(key).size : 0);
    for (const [name, target] of [["window", window], ["document", document]]) {
      const add = target.addEventListener.bind(target);
      const remove = target.removeEventListener.bind(target);
      target.addEventListener = (type, cb, opts) => {
        const key = `${name}:${type}`;
        if (!live.has(key)) live.set(key, new Set());
        if (cb) live.get(key).add(cb);
        return add(type, cb, opts);
      };
      target.removeEventListener = (type, cb, opts) => {
        const key = `${name}:${type}`;
        if (live.has(key)) live.get(key).delete(cb);
        return remove(type, cb, opts);
      };
    }
  });
}

// The board only POSTs /enter for a wallet it believes can fund the entry, and
// what it believes survives from earlier specs in the lane. So the session is
// told, the way e2e/entry_payment_retry.spec.js tells it, that one free entry
// is held; without this the hold opens the funding panel instead.
async function holdOneToken(page) {
  await page.waitForFunction(() => typeof window.refreshSession === "function");
  await page.route("**/account/session_refresh", (route) =>
    route.fulfill(json(200, { usdc: "0.0", usdt: "0.0", tokens: "1" }))
  );
  await expect
    .poll(
      async () => {
        await page.evaluate(() => window.refreshSession().catch(() => null));
        return page.evaluate(() => Alpine.store("session").tokensAvailable);
      },
      { timeout: 20000, intervals: [500, 1000, 1000, 1500, 2000] }
    )
    .toBe(1);
}

async function signedInBoard(page) {
  await setupPhantomMock(page);
  await loginViaPhantom(page);
  for (const [path, form] of [["/onboarding/first_name", { first_name: "Testy" }], ["/age/verify", { date_of_birth: "1985-04-02" }]]) {
    const res = await page.request.post(path, { form });
    if (!res.ok()) throw new Error(`${path} failed: ${res.status()}`);
  }
  await page.goto(CONTEST_PATH);
  await page.waitForFunction(() => !!document.querySelector(".hold-btn") && !!window.Alpine);
}

// Every /enter that leaves the browser, held open until the test lets it go, so
// a second request has the whole in-flight window to show itself.
async function countEnters(page) {
  const seen = { count: 0, release: null };
  const gate = new Promise((resolve) => (seen.release = resolve));
  await page.route("**/contests/*/check_funding", async (route) => {
    // Slow enough that the pre-check is still open when the hold completes.
    await new Promise((resolve) => setTimeout(resolve, 300));
    await route.fulfill(json(200, { fundable: true, reason: null, method: "token" })).catch(() => {});
  });
  await page.route("**/contests/*/enter", async (route) => {
    seen.count += 1;
    await gate;
    await route.fulfill(json(422, { success: false, error: "Stopped by the spec.", code: "spec_stop" })).catch(() => {});
  });
  return seen;
}

const HOLD_SUCCESS = "document:hold-button:success";

// What the hold button does: it dispatches hold-button:<name> on itself, and
// the event bubbles to the board's listeners on document.
const holdEvent = (page, name, times = 1) =>
  page.evaluate(
    ([eventName, count]) => {
      const button = document.querySelector('.hold-btn[data-hold-id="desktop"]');
      for (let i = 0; i < count; i++) {
        button.dispatchEvent(new CustomEvent(`hold-button:${eventName}`, { bubbles: true, cancelable: true, detail: { id: "desktop" } }));
      }
    },
    [name, times]
  );

// Six picks, so the cart's hold button is on screen and its guard passes.
async function pickSix(page) {
  const cards = page.locator('[x-data*="selectionBoard"] button[role="checkbox"]:not([disabled])');
  for (let i = 0; i < 6; i++) {
    const blurOverlay = page.locator("div.fixed.inset-0.z-20.cursor-pointer");
    if (await blurOverlay.isVisible({ timeout: 300 }).catch(() => false)) await blurOverlay.click();
    await cards.nth(i).click();
    await expect(page.locator("body")).toContainText(`${i + 1} / 6`);
  }
}

// A REAL hold: the pointer goes down on the cart's button and stays down past
// its two seconds, so the button itself decides to fire.
async function holdTheButton(page) {
  const button = page.locator('.hold-btn[data-hold-id="desktop"]');
  await expect(button).toBeVisible();
  const box = await button.boundingBox();
  await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
  await page.mouse.down();
  await page.waitForTimeout(2600);
  await page.mouse.up();
}

// A real Turbo visit and a real restoration visit. page.goto() is a full load
// that builds a new window, which would pass against the broken build.
async function leaveAndComeBack(page) {
  await page.getByRole("link", { name: "Rules" }).first().click();
  await page.waitForURL((u) => !u.pathname.startsWith("/contests"));
  await page.waitForFunction(() => !document.querySelector('[x-data*="selectionBoard"]'));
  await page.goBack();
  await page.waitForURL((u) => u.pathname.startsWith("/contests"));
  await page.waitForFunction(() => {
    const el = document.querySelector('[x-data*="selectionBoard"]');
    return !!el && !!window.Alpine && !!el._x_dataStack;
  });
}

test("after a Turbo visit away and Back, one hold sends exactly one POST /enter", async ({ page }) => {
  await censusListeners(page);
  await signedInBoard(page);
  await holdOneToken(page);
  await pickSix(page);
  expect(await page.evaluate((key) => window.__listenerCensus(key), HOLD_SUCCESS), "a fresh board listens once").toBe(1);

  await leaveAndComeBack(page);
  await holdOneToken(page);

  // Soft, so a leak reports its listener count AND its request count together.
  expect
    .soft(
      await page.evaluate((key) => window.__listenerCensus(key), HOLD_SUCCESS),
      "the board that left took its hold listener with it"
    )
    .toBe(1);

  await expect(page.locator("body")).toContainText("6 / 6");
  const enters = await countEnters(page);
  await holdTheButton(page);
  await expect.poll(() => enters.count, { message: "the hold reached /enter" }).toBeGreaterThanOrEqual(1);
  // The first request is still open: a second listener has had its turn by now.
  await page.waitForTimeout(2500);
  expect(enters.count, "one hold, one request").toBe(1);
  enters.release();
});

// THE WINDOW THIS CLOSES IS A MANAGED WALLET'S. A hold START fires the funding
// pre-check, which only a web2 session runs, and confirmEntry() waits on that
// answer BEFORE it marks itself submitting. A second complete arriving inside
// the wait finds nothing to wait for and posts; the first then wakes and posts
// too. The lane signs in through the Phantom mock, so the session is told it is
// web2 for this one page: the board reads the mode live from the store.
//
// CONTROL (same run as above): without the in-flight flag on the listener this
// reads 2 requests.
test("a second confirm while the first is still in flight sends nothing", async ({ page }) => {
  await signedInBoard(page);
  await holdOneToken(page);

  const enters = await countEnters(page);
  // Two completes in one tick, then a third once the request is open: the
  // shapes a double press and an early-action-plus-success pair both take.
  await page.evaluate(() => (Alpine.store("session").mode = "web2"));
  await holdEvent(page, "start");
  await holdEvent(page, "success", 2);
  await expect.poll(() => enters.count, { message: "the hold reached /enter" }).toBeGreaterThanOrEqual(1);
  await holdEvent(page, "success");
  await page.waitForTimeout(2500);
  expect(enters.count, "the confirms that arrived mid-flight were ignored").toBe(1);
  enters.release();
});

// THE BUTTON'S OWN EVENTS (task turf-hold-button-uses-events). The cart's
// button carries no JavaScript for the engine to evaluate: it dispatches
// hold-button:* and the board answers. A real hold, released after it
// completes, is one request; a second hold is one more.
const STRING_HOOKS = ["data-guard", "data-on-hold-start", "data-validate", "data-early-action", "data-early-action-guard", "data-on-success"];

// Every hold-button event the page dispatches, by name, counted at document.
async function recordHoldEvents(page) {
  await page.evaluate(() => {
    window.__holdEvents = {};
    for (const name of ["guard", "start", "validate", "early", "success"]) {
      document.addEventListener(`hold-button:${name}`, (event) => {
        const seen = (window.__holdEvents[name] = window.__holdEvents[name] || []);
        // Read after the board's listeners have had their turn.
        setTimeout(() => seen.push({ id: event.detail.id, prevented: event.defaultPrevented }), 0);
      });
    }
  });
}

// /enter answers each request, so the board is free for the next hold.
async function answerEnters(page) {
  const seen = { count: 0 };
  await page.route("**/contests/*/check_funding", (route) =>
    route.fulfill(json(200, { fundable: true, reason: null, method: "token" })).catch(() => {})
  );
  await page.route("**/contests/*/enter", async (route) => {
    seen.count += 1;
    await new Promise((resolve) => setTimeout(resolve, 400));
    await route.fulfill(json(422, { success: false, error: "Stopped by the spec.", code: "spec_stop" })).catch(() => {});
  });
  return seen;
}

// Put the page back to a cart ready to hold: every card the refusal opened is closed.
async function dismissRefusal(page) {
  await page.evaluate(() => {
    const solana = Alpine.store("solanaModal");
    if (solana && solana.visible) solana.close();
    const modals = Alpine.store("modals");
    for (let i = 0; i < 5 && modals && modals.current(); i++) modals.close();
  });
  await expect(page.locator('.hold-btn[data-hold-id="desktop"]')).not.toHaveClass(/process|loading|success|error/);
}

test("a hold released after it completes sends one POST /enter, and a second hold one more", async ({ page }) => {
  await signedInBoard(page);
  await holdOneToken(page);
  await pickSix(page);

  const button = page.locator('.hold-btn[data-hold-id="desktop"]');
  for (const attribute of STRING_HOOKS) await expect(button, `no ${attribute} for the engine to evaluate`).not.toHaveAttribute(attribute);
  expect(await page.locator(STRING_HOOKS.map((name) => `[${name}]`).join(",")).count(), "no string hook anywhere on the page").toBe(0);

  await recordHoldEvents(page);
  const enters = await answerEnters(page);

  await holdTheButton(page);
  await expect.poll(() => enters.count, { message: "the first hold reached /enter" }).toBeGreaterThanOrEqual(1);
  await page.waitForTimeout(2000);
  expect(enters.count, "one hold, one request").toBe(1);
  const first = await page.evaluate(() => window.__holdEvents);
  expect(first.success, "the button completed once and the board took its state").toEqual([{ id: "desktop", prevented: true }]);
  expect(first.guard, "the full cart let the press through").toEqual([{ id: "desktop", prevented: false }]);
  expect(first.start.length, "the hold start was heard once").toBe(1);
  expect(first.validate.length, "validation ran once").toBe(1);

  await dismissRefusal(page);
  await expect(page.locator("body")).toContainText("6 / 6");
  await holdTheButton(page);
  await expect.poll(() => enters.count, { message: "the second hold reached /enter" }).toBeGreaterThanOrEqual(2);
  await page.waitForTimeout(2000);
  expect(enters.count, "two holds, two requests").toBe(2);
  expect((await page.evaluate(() => window.__holdEvents)).success.length, "each hold completed once").toBe(2);
});

// A press on a cart that is not full is refused by the board's guard listener,
// so nothing after it runs.
test("a hold on a cart that is not full is refused and sends nothing", async ({ page }) => {
  await signedInBoard(page);
  await holdOneToken(page);
  await recordHoldEvents(page);
  const enters = await answerEnters(page);

  // The button is in the page but its row is hidden until the cart is full, so
  // the press is dispatched on it, as the pointer would.
  await page.evaluate(() => document.querySelector('.hold-btn[data-hold-id="desktop"]').dispatchEvent(new MouseEvent("mousedown", { bubbles: true })));
  await page.waitForTimeout(2600);
  await page.evaluate(() => document.querySelector('.hold-btn[data-hold-id="desktop"]').dispatchEvent(new MouseEvent("mouseup", { bubbles: true })));

  const events = await page.evaluate(() => window.__holdEvents);
  expect(events.guard, "the board refused the press").toEqual([{ id: "desktop", prevented: true }]);
  expect(events.start, "a refused press starts nothing").toBeUndefined();
  expect(events.success, "and completes nothing").toBeUndefined();
  expect(enters.count).toBe(0);
});
