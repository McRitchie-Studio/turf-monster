const { test, expect } = require("@playwright/test");
const { reseed } = require("./helpers");

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
  await expect(page.getByRole("heading", { name: /Verify your age/i })).toBeVisible({ timeout: 15000 });
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

  await expect(page.getByRole("heading", { name: /Verify your age/i })).toBeVisible({ timeout: 15000 });
  await fillDob(page);
  await page.getByRole("button", { name: /Confirm & Continue/i }).click();
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible({ timeout: 20000 });
});

test("the wallet step offers the way back to Buy an Entry Token @smoke", async ({ page }) => {
  // The operator's escape hatch. It is a SWAP, so the assertion is not just that
  // the token modal appears — the wallet card must be GONE, or the user is
  // looking at two stacked modals.
  await signUpFresh(page, { contest: "world-cup-2026" });
  await page.getByRole("button", { name: "Skip for now" }).click();
  await expect(page.getByRole("heading", { name: /Verify your age/i })).toBeVisible({ timeout: 15000 });
  await fillDob(page);
  await page.getByRole("button", { name: /Confirm & Continue/i }).click();
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible({ timeout: 20000 });

  await page.getByRole("button", { name: /Buy an entry token/i }).click();
  await expect(page.getByRole("heading", { name: "Buy an Entry Token" })).toBeVisible({ timeout: 15000 });
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeHidden();
  expect(await currentModal(page)).toMatchObject({ id: "buy-entry-token" });
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
  await expect(page.getByRole("heading", { name: /Verify your age/i })).toBeVisible({ timeout: 15000 });
  const next = await page.evaluate(() =>
    window.eligibilityBlocker(Alpine.store("session"), 1900, { acceptsUsdt: false })
  );
  expect(next.reason).toBe("age_required");
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
  await expect(page.getByRole("heading", { name: /Verify your age/i })).toBeVisible({ timeout: 15000 });
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
  await expect(page.getByRole("heading", { name: /Verify your age/i })).toBeVisible({ timeout: 15000 });
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
  await expect(page.getByRole("heading", { name: /Verify your age/i })).toBeHidden();
  await expect(page.getByRole("heading", { name: /You're in/i })).toBeHidden();
  // The wallet step is the one thing still outstanding (they clicked Maybe
  // later), so IT may reopen — but nothing already satisfied may.
});
