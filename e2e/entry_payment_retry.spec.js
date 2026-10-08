const { test, expect } = require("@playwright/test");
const { loginViaPhantom } = require("./helpers");
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

const json = (status, body) => ({ status, contentType: "application/json", body: JSON.stringify(body) });

async function board(page) {
  await page.waitForFunction(() => !!document.querySelector(".hold-btn") && !!window.Alpine);
  return page.evaluateHandle(() => Alpine.$data(document.querySelector(".hold-btn").closest("[x-data]")));
}

// The on-chain card's live state, read from the modal host.
const card = (page) =>
  page.evaluate(() => {
    const live = Alpine.store("modals").stack.filter((m) => m.id === "onchain-tx" && !m._closing).pop();
    return live ? { state: live.props.state, title: live.props.title, message: live.props.message, error: live.props.errorMessage } : null;
  });

test("hold, pending, not charged, hold again: one entry, and every step says what happened", async ({ page }) => {
  await setupPhantomMock(page);
  await loginViaPhantom(page);
  for (const [path, form] of [["/onboarding/first_name", { first_name: "Testy" }], ["/age/verify", { date_of_birth: "1985-04-02" }]]) {
    const res = await page.request.post(path, { form });
    if (!res.ok()) throw new Error(`${path} failed: ${res.status()}`);
  }
  await page.goto(CONTEST_PATH);

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
