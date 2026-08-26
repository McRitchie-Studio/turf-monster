const { test, expect } = require("@playwright/test");
const { reseed, grantManagedWallet, allowMotion } = require("./helpers");

// The post-auth onboarding chain (operator spec 2026-08-15):
//   first name → age gate → wallet setup
//
// A `welcome` card ("You're in", the auto-generated username) opened this chain
// until 2026-08-15 and was retired: it cost a click to deliver something the user
// had not asked for. The chain greets with the first real question now, and the
// negative assertions below are what keep it that way — a resurrected welcome
// card would still let every positive assertion here pass, one click later.
//
// Only a browser can prove the ORDER, because the order lives in the layout's
// chain driver plus each modal's hand-off event — the server just resolves which
// steps are outstanding. A markup tier can assert every step renders and still
// miss a broken hand-off that strands the user after step one.
test.setTimeout(90_000);

test.beforeEach(async ({ request }) => await reseed(request));

// Sign up a brand-new email through the real magic-link round trip.
//
// NOT /_studio/local_review: that dev endpoint CREATES the user before minting,
// so consume takes the returning-login path. Signup and login now resolve to the
// SAME chain, so that no longer changes which steps appear — but /test/magic_link_token
// only mints, which is what an emailed link actually does, so these specs keep
// exercising the path a real new player takes.
async function signUpFresh(page, { contest } = {}) {
  const email = `chain-${Date.now().toString(36)}@example.com`;
  const resp = await page.request.post("/test/magic_link_token", {
    data: contest ? { email, contest } : { email },
  });
  expect(resp.ok()).toBeTruthy();
  const { url } = await resp.json();
  await page.goto(url);
  await page.waitForURL(
    (u) => !u.pathname.startsWith("/signin") && !u.pathname.startsWith("/magic_link") && !u.pathname.startsWith("/l/")
  );
  return email;
}

// Which modal the shared host currently shows.
async function currentModal(page) {
  return page.evaluate(() => {
    const m = window.Alpine && Alpine.store && Alpine.store("modals");
    const c = m && m.current && m.current();
    return c ? { id: c.id } : null;
  });
}

async function fillDob(page, { year = "1990", month = "6", day = "15" } = {}) {
  const ok = await page.evaluate(
    (dob) => {
      const els = document.querySelectorAll("[x-data]");
      for (const el of els) {
        const d = Alpine.$data(el);
        if (d && "year" in d && "month" in d && "day" in d) {
          d.year = dob.year;
          d.month = dob.month;
          d.day = dob.day;
          return true;
        }
      }
      return false;
    },
    { year, month, day }
  );
  expect(ok, "age modal x-data not found").toBeTruthy();
}

test("a new signup walks first name → age → wallet in order @smoke", async ({ page }) => {
  await signUpFresh(page, { contest: "world-cup-2026" });

  // 1. First name — the FIRST thing a new account meets. No welcome card, and
  //    no "Let's go" button to get past one.
  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeVisible();
  expect(await currentModal(page)).toMatchObject({ id: "onboarding" });
  await expect(page.getByRole("heading", { name: /You're in/i })).toBeHidden();

  await page.fill("#onboarding-first-name", "Alex");
  await page.getByRole("button", { name: /Save and continue/i }).click();

  // 2. Age gate — moved here from contest entry.
  await expect(page.getByRole("heading", { name: /Your birthday/i })).toBeVisible({ timeout: 15000 });
  await fillDob(page);
  await page.getByRole("button", { name: /Confirm & Continue/i }).click();

  // 3. Wallet setup — the last step of onboarding, where Buy an Entry Token used
  //    to land before web3-only onboarding took the season.
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible({ timeout: 20000 });
  expect(await currentModal(page)).toMatchObject({ id: "wallet-setup" });
});

test("the first-name field is focused on open, so the user can just type @smoke", async ({ page }) => {
  // Only a browser can prove this: the HTML autofocus attribute does nothing for
  // a modal mounted from <template x-if> after the document parsed, so the focus
  // comes from Alpine ($nextTick + $el.focus). Asserting activeElement alone
  // could pass on a field that is focused but unusable, so type WITHOUT clicking
  // and check the value landed.
  //
  // Sharper than it was: the field is focused on the chain's FIRST card now, so
  // this proves a new player can type their name without touching the mouse at
  // all — there is no longer a welcome click in front of it to do the focusing.
  await signUpFresh(page, { contest: "world-cup-2026" });
  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeVisible();

  await expect(page.locator("#onboarding-first-name")).toBeFocused();
  await page.keyboard.type("Alex");
  await expect(page.locator("#onboarding-first-name")).toHaveValue("Alex");
});

test("skipping the first name still reaches the age and wallet steps @smoke", async ({ page }) => {
  // Skippable was an explicit operator call, and the risk in a skip is that it
  // ends the chain instead of advancing it.
  await signUpFresh(page, { contest: "world-cup-2026" });
  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeVisible();

  await page.getByRole("button", { name: "Skip for now" }).click();

  await expect(page.getByRole("heading", { name: /Your birthday/i })).toBeVisible({ timeout: 15000 });
  await fillDob(page);
  await page.getByRole("button", { name: /Confirm & Continue/i }).click();
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible({ timeout: 20000 });
});

// Walk a fresh signup to the wallet-setup card.
async function reachWalletStep(page) {
  await signUpFresh(page, { contest: "world-cup-2026" });
  await page.getByRole("button", { name: "Skip for now" }).click();
  await expect(page.getByRole("heading", { name: /Your birthday/i })).toBeVisible({ timeout: 15000 });
  await fillDob(page);
  await page.getByRole("button", { name: /Confirm & Continue/i }).click();
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible({ timeout: 20000 });
}

test("a wallet-less player is told why the card rail cannot work yet @smoke", async ({ page }) => {
  // THE BLOCKER (2026-08-15): this card's card-payment link used to be a plain
  // button for everyone, and every entry-token rail refuses a wallet-less
  // buyer — so it dead-ended for exactly the audience web3-only onboarding
  // created. Visible and explained, never a dead button (operator's call).
  await reachWalletStep(page);

  await expect(page.getByText(/Link a wallet first/i)).toBeVisible();
  await expect(page.getByRole("button", { name: /Buy an entry token/i })).toBeHidden();
});

test("with a wallet the link opens the token modal AND its rail works @smoke", async ({ page }) => {
  // The grandfathered managed-wallet player the link genuinely serves. This is
  // the coverage the blocker asked for: CI stayed green on the dead-end because
  // this spec only ever asserted that the swap landed — it never clicked a rail,
  // so the refusal behind it was never executed.
  await reachWalletStep(page);
  await grantManagedWallet(page);
  await page.reload();                       // walletConnected is server-rendered
  await page.waitForLoadState("networkidle");
  await page.evaluate(() => Alpine.store("modals").open("wallet-setup", {}));
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible();

  // A SWAP, so the assertion is not just that the token modal appears — the
  // wallet card must be GONE, or the user is looking at two stacked modals.
  await page.getByRole("button", { name: /Buy an entry token/i }).click();
  await expect(page.getByRole("heading", { name: "Buy an Entry Token" })).toBeVisible({ timeout: 15000 });
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeHidden();
  expect(await currentModal(page)).toMatchObject({ id: "buy-entry-token" });

  // CLICK THROUGH the rail. Coinflow is the one that reaches the server
  // (tmCoinflowBuyOne POSTs /tokens/coinflow_order); the Stripe card is a
  // client-side swap into the picker and would prove nothing here. Assert on the
  // RESPONSE rather than the absence of an alert: Coinflow may be unconfigured
  // on this lane and fail for its own reasons, and what must never come back is
  // the wallet refusal.
  page.on("dialog", (d) => d.dismiss());     // keep an alert from blocking the run
  const [orderResp] = await Promise.all([
    page.waitForResponse((r) => r.url().includes("/tokens/coinflow_order"), { timeout: 20000 }),
    page.locator('[data-buy-rail="coinflow"]').click(),
  ]);
  const body = await orderResp.json().catch(() => ({}));
  expect(body.error || "", "the rail must not refuse a buyer who HAS a wallet").not.toMatch(/connect a wallet/i);
});

test("the first name is the FIRST validation of the hold @smoke", async ({ page }) => {
  // Operator call, 2026-08-15. Only a browser can prove this ordering: the gate
  // lives in eligibilityBlocker (an importmap module) and its blocker is
  // dispatched by the board, so a server tier can assert both halves exist and
  // still miss a card that never opens.
  //
  // The chain's card is SKIPPED first, deliberately — that leaves the name blank
  // with a session skip recorded, which is exactly the state a chain-derived
  // flag would wave through. Reaching the card again at the hold is the proof
  // the gate reads the column instead.
  await signUpFresh(page, { contest: "world-cup-2026" });
  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeVisible();
  await page.getByRole("button", { name: "Skip for now" }).click();
  await page.keyboard.press("Escape"); // abandon the rest of the chain
  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeHidden();

  const blocker = await page.evaluate(() =>
    window.eligibilityBlocker(Alpine.store("session"), 1900, { acceptsUsdt: false })
  );
  expect(blocker).not.toBeNull();
  expect(blocker.reason).toBe("first_name_required");

  // And the card it dispatches to is the REQUIRED one — no way to skip past a
  // validation the hold will re-apply on the next attempt.
  await page.evaluate(() => Alpine.store("modals").open("onboarding", { required: true }));
  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeVisible();
  await expect(page.getByRole("button", { name: "Skip for now" })).toBeHidden();

  // Saving clears the gate, so the hold's next validation is the age gate.
  await page.fill("#onboarding-first-name", "Alex");
  await page.getByRole("button", { name: /Save and continue/i }).click();
  await expect(page.getByRole("heading", { name: /Your birthday/i })).toBeVisible({ timeout: 15000 });
  const next = await page.evaluate(() =>
    window.eligibilityBlocker(Alpine.store("session"), 1900, { acceptsUsdt: false })
  );
  expect(next.reason).toBe("age_required");
});

test("the first-name placeholder types itself, then yields to the user @smoke", async ({ page }) => {
  // MOTION ON, ON PURPOSE. The lane runs prefers-reduced-motion by default since
  // /tasks/make-reduced-motion-reach-specs, and the modal honors it:
  // `startPlaceholder()` assigns the whole name and RETURNS
  // (modals/_onboarding.html.erb:67), because the hint is the point and the
  // typing is decoration. This spec asserts the typing ANIMATES — "the
  // placeholder must pass through many states, not one" — so it opts out.
  await allowMotion(page);
  // Only a browser can prove an animation animates. A markup tier can assert
  // every handler is wired and still miss a timer that never ticks.
  await signUpFresh(page, { contest: "world-cup-2026" });
  const field = page.locator("#onboarding-first-name");
  await expect(field).toBeVisible();

  // 1. It settles on a WHOLE name from the pool the server rendered. Read the
  //    pool off the DOM rather than hard-coding it here, so editing the QB list
  //    never breaks this spec.
  const pool = await page.evaluate(() =>
    JSON.parse(document.querySelector("[data-placeholder-names]").dataset.placeholderNames)
  );
  await page.waitForFunction(
    (names) => names.includes(document.querySelector("#onboarding-first-name").placeholder),
    pool,
    { timeout: 5000 }
  );

  // 2. It GREW there rather than being assigned. Re-run the animation with a
  //    known long phrase so this is deterministic — sampling the natural mount
  //    races a two-character name like "Bo", which finishes in ~170ms.
  const frames = await page.evaluate(async () => {
    const el = document.querySelector("#onboarding-first-name");
    Alpine.$data(el).startPlaceholder(["Quarterback"]);
    // startPlaceholder resets the state synchronously, but :placeholder is an
    // Alpine binding and flushes on a MICROTASK — so for an instant the element
    // still shows the name the natural mount typed. Sampling through that window
    // captures a leftover ("Josh") that is not a prefix of this phrase. Wait for
    // the reset to reach the DOM first.
    const resetBy = Date.now() + 1000;
    while (el.placeholder !== "" && Date.now() < resetBy) {
      await new Promise((r) => setTimeout(r, 5));
    }
    // Sample until it FINISHES rather than for a fixed number of ticks. A count
    // encodes an assumption about the typing speed: 30 x 30ms stopped one tick
    // short of an 11-character phrase at 85ms/char and failed on "Quarterbac".
    const seen = [];
    const deadline = Date.now() + 5000;
    while (Date.now() < deadline) {
      seen.push(el.placeholder);
      if (el.placeholder === "Quarterback") break;
      await new Promise((r) => setTimeout(r, 25));
    }
    return seen;
  });
  const distinct = [...new Set(frames)];
  expect(distinct.length, "the placeholder must pass through many states, not one").toBeGreaterThan(3);

  // THE PRE-ROLL. Typing must not begin until the modal's 320ms entrance has
  // landed. Without this the effect is invisible for exactly the common case —
  // a short name finishes underneath the card animation and the field simply
  // appears with a name already in it, which is what the operator saw. Counting
  // leading empty frames rather than asserting a stopwatch keeps it honest
  // without being flaky: at 25ms per sample a 420ms delay is ~16 of them.
  const leadingEmpty = frames.findIndex((f) => f !== "");
  expect(leadingEmpty, "typing must wait for the card to settle").toBeGreaterThan(3);
  expect(frames[frames.length - 1]).toBe("Quarterback");
  // Every frame is a prefix of the finished phrase, in non-decreasing length —
  // i.e. it TYPED, never jumped or rewound.
  frames.forEach((f) => expect("Quarterback".startsWith(f)).toBe(true));
  for (let i = 1; i < frames.length; i++) {
    expect(frames[i].length).toBeGreaterThanOrEqual(frames[i - 1].length);
  }

  // 3. The user's own typing clears it, so the hint never sits under their text.
  await field.type("Al");
  await expect.poll(async () => await field.getAttribute("placeholder")).toBe("");
});

test("the chain does not re-open on later navigation", async ({ page }) => {
  await signUpFresh(page, { contest: "world-cup-2026" });
  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeVisible();

  // Dismiss the whole chain by closing the card.
  await page.keyboard.press("Escape");
  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeHidden();

  await page.goto("/contests");
  await page.waitForLoadState("networkidle");
  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeHidden();
  await expect(page.getByRole("heading", { name: /You're in/i })).toBeHidden();
});

test("dismissing the chain still leaves the age gate enforced at entry", async ({ page }) => {
  // THE compliance property. Moving the age PROMPT earlier must not move the
  // age GATE: a user who closes the chain and goes straight for an entry is
  // still stopped. Driving the client blocker directly (the hold gesture is
  // timing-flaky — same approach as geo_hold_validation.spec.js).
  await signUpFresh(page, { contest: "world-cup-2026" });
  // ANSWER the name first: since 2026-08-15 it is the hold's first validation,
  // so a skipped name would make the blocker below read first_name_required and
  // this spec would stop testing the age gate while still passing an
  // "is not null" check. Saving it is what puts age back in front.
  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeVisible();
  await page.fill("#onboarding-first-name", "Alex");
  await page.getByRole("button", { name: /Save and continue/i }).click();
  await expect(page.getByRole("heading", { name: /Your birthday/i })).toBeVisible({ timeout: 15000 });
  await page.keyboard.press("Escape");

  const blocker = await page.evaluate(() =>
    window.eligibilityBlocker(Alpine.store("session"), 1900, { acceptsUsdt: false })
  );
  expect(blocker).not.toBeNull();
  expect(blocker.reason).toBe("age_required");
});

test("a returning user who owes nothing sees no chain at all", async ({ page }) => {
  // Sign up, complete every step, then sign in again: the chain must be silent.
  const email = await signUpFresh(page, { contest: "world-cup-2026" });
  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeVisible();
  await page.fill("#onboarding-first-name", "Alex");
  await page.getByRole("button", { name: /Save and continue/i }).click();
  await expect(page.getByRole("heading", { name: /Your birthday/i })).toBeVisible({ timeout: 15000 });
  await fillDob(page);
  await page.getByRole("button", { name: /Confirm & Continue/i }).click();
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible({ timeout: 20000 });
  await page.getByRole("button", { name: "Maybe later" }).click();

  // Same email, fresh link — a login, not a signup.
  const resp = await page.request.post("/test/magic_link_token", { data: { email } });
  const { url } = await resp.json();
  await page.goto(url);
  await page.waitForURL((u) => !u.pathname.startsWith("/magic_link") && !u.pathname.startsWith("/l/"));
  await page.waitForTimeout(1500);

  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeHidden();
  await expect(page.getByRole("heading", { name: /Your birthday/i })).toBeHidden();
  await expect(page.getByRole("heading", { name: /You're in/i })).toBeHidden();
  // The wallet step is the one thing still outstanding (they clicked Maybe
  // later), so IT may reopen — but nothing already satisfied may.
});
