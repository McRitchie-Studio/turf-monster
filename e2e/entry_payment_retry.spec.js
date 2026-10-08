const { test, expect } = require("@playwright/test");
const { loginViaPhantom, reseed } = require("./helpers");
const { setupPhantomMock } = require("./phantom-mock");

// THE RETRY FLOW, AS THE PLAYER SEES IT (task entry-payment-state-machine).
//
// Hold, the payment's outcome is unknown, the card says so in a sentence and
// polls; the chain says it never landed, the card says "you were not charged"
// and why; hold again, and the entry is confirmed, once.
//
// The server's answers are stubbed at the route, in the exact shapes
// ContestsController#enter and #entry_payment_status render (pinned by
// test/controllers/contests_entry_payment_test.rb), so this spec is about the
// one thing a controller test cannot see: what the board does with them. It
// must never show a raw error, never leave a spinner with no end, and never
// send a second /enter on its own.

const CONTEST_PATH = "/contests/world-cup-2026";
const PENDING = "Your entry was sent and is still confirming on Solana. We are checking it now. You will not be charged twice.";
const NEVER_LANDED = "Your last attempt never reached Solana, so you were not charged. Your picks are saved. Try again.";

// The lane shares one database: clear throttles and cached session state
// before each login, as every spec that signs in does.
test.beforeEach(async ({ request }) => await reseed(request));

const json = (status, body) => ({ status, contentType: "application/json", body: JSON.stringify(body) });

async function board(page) {
  await page.waitForFunction(() => !!document.querySelector(".hold-btn") && !!window.Alpine);
  return page.evaluateHandle(() => Alpine.$data(document.querySelector(".hold-btn").closest("[x-data]")));
}

// The board only POSTs /enter for a wallet it believes can fund the entry, and
// what it believes survives from earlier specs in the lane. So the session is
// told, the way e2e/free_entry_spend_mirror.spec.js tells it, that one free
// entry is held; without this the hold opens the funding panel instead.
async function holdOneToken(page) {
  await page.waitForFunction(() => typeof window.refreshSession === "function");
  await page.waitForTimeout(1500);
  await page.route("**/account/session_refresh", (route) =>
    route.fulfill(json(200, { usdc: "0.0", usdt: "0.0", tokens: "1" }))
  );
  await expect
    .poll(
      async () => {
        await page.evaluate(() => window.refreshSession().catch(() => null));
        return page.evaluate(() => Alpine.store("session").tokensAvailable);
      },
      { timeout: 20000, intervals: [1000, 1000, 1000, 1500, 1500, 2000, 2000, 2000] }
    )
    .toBe(1);
  await page.waitForTimeout(1500);
  await page.evaluate(() => window.refreshSession().catch(() => null));
  await expect.poll(() => page.evaluate(() => Alpine.store("session").tokensAvailable)).toBe(1);
}

// The on-chain card's live state, read from the modal host.
const card = (page) =>
  page.evaluate(() => {
    const live = Alpine.store("modals").stack.filter((m) => m.id === "onchain-tx" && !m._closing).pop();
    if (!live) return null;
    const p = live.props;
    return { state: p.state, title: p.title, message: p.message, error: p.errorMessage, successTitle: p.successTitle, successSubtitle: p.successSubtitle, ctaHref: p.ctaHref };
  });

test("hold, pending, not charged, hold again: one entry, and every step says what happened", async ({ page }) => {
  await setupPhantomMock(page);
  await loginViaPhantom(page);
  for (const [path, form] of [["/onboarding/first_name", { first_name: "Testy" }], ["/age/verify", { date_of_birth: "1985-04-02" }]]) {
    const res = await page.request.post(path, { form });
    if (!res.ok()) throw new Error(`${path} failed: ${res.status()}`);
  }
  await page.goto(CONTEST_PATH);
  await holdOneToken(page);

  let holds = 0;
  let polls = 0;
  await page.route("**/contests/*/check_funding", (route) => route.fulfill(json(200, { fundable: true, reason: null, method: "token" })));
  await page.route("**/contests/*/enter", (route) => {
    holds += 1;
    if (holds === 1) {
      return route.fulfill(json(202, { success: false, code: "entry_pending", error: PENDING, retry: false, entry: "testy-cart-1" }));
    }
    return route.fulfill(json(200, { success: true, redirect: CONTEST_PATH, tx_signature: "SIG_SECOND_HOLD", token_consumed: false }));
  });
  await page.route("**/contests/*/entry_payment_status", (route) => {
    polls += 1;
    expect(route.request().postDataJSON()).toEqual({ entry: "testy-cart-1" });
    if (polls === 1) return route.fulfill(json(200, { status: "pending", code: "pending", error: PENDING, retry: false }));
    return route.fulfill(json(200, { status: "retry", code: "expired", error: NEVER_LANDED, retry: true }));
  });

  const b = await board(page);

  // 1. Hold. The outcome is unknown: a titled card with the sentence, polling.
  await b.evaluate((c) => c.confirmEntry());
  await expect.poll(() => holds, { message: "the hold reached /enter" }).toBe(1);
  await expect.poll(() => card(page)).toMatchObject({ state: "processing", title: "Entry Still Confirming", message: PENDING });
  await expect(page.getByText(PENDING)).toBeVisible();
  expect(holds).toBe(1);

  // 2. The chain says it never landed: the card ends, says so, and the hold is live again.
  await expect.poll(() => card(page), { timeout: 15000 }).toMatchObject({ state: "error", title: "You Were Not Charged", error: NEVER_LANDED });
  await expect(page.getByText(NEVER_LANDED)).toBeVisible();
  expect(polls).toBe(2);
  expect(holds, "the page never retried the payment by itself").toBe(1);
  expect(await b.evaluate((c) => c.submitting)).toBe(false);

  // 3. The poll has stopped: a card that ended asks the server nothing more.
  await page.waitForTimeout(3500);
  expect(polls).toBe(2);

  // 4. Hold again: confirmed, from exactly one more request.
  await page.evaluate(() => Alpine.store("solanaModal").close());
  await b.evaluate((c) => c.confirmEntry());
  await expect.poll(() => holds).toBe(2);
  // Counted on the test's side, so the success redirect cannot race the read.
  await page.waitForTimeout(1000);
  expect(holds, "one request confirmed it").toBe(2);
  expect(polls, "a confirmed hold opens no poll").toBe(2);
});

test("a payment that outlasts the poll ends in a sentence, not a spinner", async ({ page }) => {
  await setupPhantomMock(page);
  await loginViaPhantom(page);
  await page.goto(CONTEST_PATH);
  await page.route("**/contests/*/entry_payment_status", (route) =>
    route.fulfill(json(200, { status: "pending", code: "pending", error: PENDING, retry: false }))
  );

  const b = await board(page);
  // The poll's own clock is the only thing sped up: 40 asks, 3 seconds apart.
  await page.evaluate(() => {
    const real = window.setTimeout;
    window.setTimeout = (fn, ms, ...rest) => real(fn, ms === 3000 ? 5 : ms, ...rest);
  });
  await b.evaluate((c) => { c.pollEntryPayment("testy-cart-1", { code: "entry_pending", error: "x" }); });

  await expect.poll(() => card(page), { timeout: 15000 }).toMatchObject({ state: "error", title: "Still Confirming" });
  const end = await card(page);
  expect(end.error).toMatch(/Your entry is safe and you will not be charged twice/);
});

// --- what the board does with the other answers (review round 2) ---------------------

async function signedInBoard(page) {
  await setupPhantomMock(page);
  await loginViaPhantom(page);
  await page.goto(CONTEST_PATH);
  return board(page);
}

const stack = (page) => page.evaluate(() => Alpine.store("modals").stack.filter((m) => !m._closing).map((m) => m.id));

test("a 429 on the poll backs off and keeps going: no second modal, and the card is not stranded", async ({ page }) => {
  const b = await signedInBoard(page);
  let polls = 0;
  await page.route("**/contests/*/entry_payment_status", (route) => {
    polls += 1;
    if (polls <= 2) return route.fulfill({ status: 429, headers: { "Retry-After": "1" }, contentType: "text/plain", body: "Retry later" });
    return route.fulfill(json(200, { status: "confirmed", redirect: "/contests", tx_signature: "SIG_AFTER_429", message: "You're in! Good luck." }));
  });

  await b.evaluate((c) => { c.pollEntryPayment("testy-cart-1", { code: "entry_pending", error: "still confirming" }); });
  await expect.poll(() => polls, { timeout: 15000 }).toBeGreaterThanOrEqual(2);
  expect(await stack(page), "the rate-limit modal was not opened over the card").toEqual(["onchain-tx"]);
  expect((await card(page)).state).toBe("processing");

  await expect.poll(() => card(page), { timeout: 15000 }).toMatchObject({ state: "success", successTitle: "You're In", ctaHref: "/contests" });
  expect(polls).toBe(3);
});

test("the confirmed card's lobby button has its address, and dismissing it leaves for the contest", async ({ page }) => {
  const b = await signedInBoard(page);
  await b.evaluate((c) => c._handleBlockerResponse({ success: false, code: "entry_confirmed", error: "Your first payment went through, so you were not charged again. You're in!", redirect: "/contests", tx_signature: "SIG_FIRST" }));

  await expect.poll(() => card(page)).toMatchObject({ state: "success", successTitle: "You're In", ctaHref: "/contests" });
  await expect(page.getByText("Your first payment went through, so you were not charged again. You're in!")).toBeVisible();
  await expect(page.getByRole("link", { name: /Contest Lobby/ })).toHaveAttribute("href", "/contests");

  await page.evaluate(() => Alpine.store("modals").close()); // Dismiss, as the engine's card does it
  await page.waitForURL("**/contests");
});

test("a pick tap answered 'already paid' or 'held' paints a card with the sentence, never an Entry Failed toast", async ({ page }) => {
  const b = await signedInBoard(page);
  const toasts = [];
  await page.exposeFunction("recordToast", (detail) => toasts.push(detail));
  await page.evaluate(() => window.addEventListener("toast", (e) => window.recordToast(e.detail)));
  const HELD = "Your payment for this contest arrived, but we could not finish the entry. You will not be charged again, and we are sorting it out. If it is not resolved within a day, contact support@turfmonster.media.";
  let answer = json(409, { success: false, code: "entry_held", error: HELD, retry: false, entry: "testy-cart-1" });
  await page.route("**/contests/*/toggle_selection", (route) => route.fulfill(answer));
  const firstPick = await page.evaluate(() => {
    const tile = Array.from(document.querySelectorAll("button")).find((el) => /toggleSelection\('\d+'\)/.test(el.getAttribute("@click") || ""));
    return tile.getAttribute("@click").match(/toggleSelection\('(\d+)'\)/)[1];
  });

  await b.evaluate((c, id) => c.toggleSelection(id), firstPick);
  await expect.poll(() => card(page)).toMatchObject({ state: "error", title: "Entry On Hold", error: HELD });
  await expect(page.getByText(HELD)).toBeVisible();
  expect(await b.evaluate((c) => Object.keys(c.selections).length), "the optimistic pick was put back").toBe(0);

  await page.evaluate(() => Alpine.store("modals").close());
  answer = json(409, { success: false, code: "entry_confirmed", error: "Your first payment went through, so you were not charged again. You're in!", redirect: "/contests", tx_signature: "SIG_FIRST" });
  await b.evaluate((c, id) => c.toggleSelection(id), firstPick);
  await expect.poll(() => card(page)).toMatchObject({ state: "success", successTitle: "You're In" });
  expect(toasts.filter((t) => t.title === "Entry Failed"), "no failure toast over a success").toEqual([]);
});

test("a clear the server refuses puts the picks back on screen", async ({ page }) => {
  const b = await signedInBoard(page);
  await page.route("**/contests/*/clear_picks", (route) =>
    route.fulfill(json(503, { success: false, code: "check_failed", retry: true, error: "We could not check your last payment just now, so nothing was changed and nothing was charged. Try again in a moment." }))
  );
  await b.evaluate((c) => { c.selections = { "101": true, "102": true }; c.selectionOrder = ["101", "102"]; });

  await b.evaluate((c) => c.clearSelections());

  expect(await b.evaluate((c) => [Object.keys(c.selections).sort(), c.selectionOrder])).toEqual([["101", "102"], ["101", "102"]]);
});

test("a /enter answer that is not JSON (the router's cut) says still confirming, not a wallet error", async ({ page }) => {
  await setupPhantomMock(page);
  await loginViaPhantom(page);
  for (const [path, form] of [["/onboarding/first_name", { first_name: "Testy" }], ["/age/verify", { date_of_birth: "1985-04-02" }]]) {
    const res = await page.request.post(path, { form });
    if (!res.ok()) throw new Error(`${path} failed: ${res.status()}`);
  }
  await page.goto(CONTEST_PATH);
  await holdOneToken(page);
  await page.route("**/contests/*/check_funding", (route) => route.fulfill(json(200, { fundable: true, reason: null, method: "token" })));
  await page.route("**/contests/*/enter", (route) =>
    route.fulfill({ status: 503, contentType: "text/html", body: "<html><body><h1>Application Error</h1></body></html>" })
  );

  const b = await board(page);
  await b.evaluate((c) => c.confirmEntry());

  await expect.poll(() => card(page)).toMatchObject({ state: "error", title: "Still Confirming" });
  const shown = await card(page);
  expect(shown.error).toMatch(/may still be confirming, and you will not be charged twice/);
  expect(shown.error).not.toMatch(/wallet/i);
});

