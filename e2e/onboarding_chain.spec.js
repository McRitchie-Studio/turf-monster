const { test, expect } = require("@playwright/test");
const { reseed } = require("./helpers");

// The post-auth onboarding chain (operator spec 2026-08-12):
//   welcome → first name → age gate → wallet setup
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
// so consume takes the returning-login path and (correctly) drops the welcome
// beat — a spec built on it could never see step one. /test/magic_link_token
// only mints, which is what an emailed link does.
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

// Which modal the shared host currently shows, and its internal step.
async function currentModal(page) {
  return page.evaluate(() => {
    const m = window.Alpine && Alpine.store && Alpine.store("modals");
    const c = m && m.current && m.current();
    return c ? { id: c.id, step: (c.props && c.props.step) || null } : null;
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

test("a new signup walks welcome → first name → age → wallet in order @smoke", async ({ page }) => {
  await signUpFresh(page, { contest: "world-cup-2026" });

  // 1. Welcome — the username, no action but continue.
  await expect(page.getByRole("heading", { name: /You're in/i })).toBeVisible();
  expect(await currentModal(page)).toMatchObject({ id: "onboarding", step: "welcome" });

  // 2. First name.
  await page.getByRole("button", { name: /Let's go/i }).click();
  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeVisible();
  expect(await currentModal(page)).toMatchObject({ id: "onboarding", step: "first-name" });

  await page.fill("#onboarding-first-name", "Alex");
  await page.getByRole("button", { name: /Save and continue/i }).click();

  // 3. Age gate — moved here from contest entry.
  await expect(page.getByRole("heading", { name: /Verify your age/i })).toBeVisible({ timeout: 15000 });
  await fillDob(page);
  await page.getByRole("button", { name: /Confirm & Continue/i }).click();

  // 4. Wallet setup.
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible({ timeout: 20000 });
  expect(await currentModal(page)).toMatchObject({ id: "wallet-setup" });
});

test("the first-name field is focused on open, so the user can just type @smoke", async ({ page }) => {
  // Only a browser can prove this: the HTML autofocus attribute does nothing for
  // a modal mounted from <template x-if> after the document parsed, so the focus
  // comes from Alpine ($nextTick + $el.focus). Asserting activeElement alone
  // could pass on a field that is focused but unusable, so type WITHOUT clicking
  // and check the value landed.
  await signUpFresh(page, { contest: "world-cup-2026" });
  await page.getByRole("button", { name: /Let's go/i }).click();
  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeVisible();

  await expect(page.locator("#onboarding-first-name")).toBeFocused();
  await page.keyboard.type("Alex");
  await expect(page.locator("#onboarding-first-name")).toHaveValue("Alex");
});

test("skipping the first name still reaches the age and wallet steps @smoke", async ({ page }) => {
  // Skippable was an explicit operator call, and the risk in a skip is that it
  // ends the chain instead of advancing it.
  await signUpFresh(page, { contest: "world-cup-2026" });
  await page.getByRole("button", { name: /Let's go/i }).click();
  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeVisible();

  await page.getByRole("button", { name: "Skip for now" }).click();

  await expect(page.getByRole("heading", { name: /Verify your age/i })).toBeVisible({ timeout: 15000 });
  await fillDob(page);
  await page.getByRole("button", { name: /Confirm & Continue/i }).click();
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeVisible({ timeout: 20000 });
});

test("the chain does not re-open on later navigation", async ({ page }) => {
  await signUpFresh(page, { contest: "world-cup-2026" });
  await expect(page.getByRole("heading", { name: /You're in/i })).toBeVisible();

  // Dismiss the whole chain by closing the card.
  await page.keyboard.press("Escape");
  await expect(page.getByRole("heading", { name: /You're in/i })).toBeHidden();

  await page.goto("/contests");
  await page.waitForLoadState("networkidle");
  await expect(page.getByRole("heading", { name: /You're in/i })).toBeHidden();
  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeHidden();
});

test("dismissing the chain still leaves the age gate enforced at entry", async ({ page }) => {
  // THE compliance property. Moving the age PROMPT earlier must not move the
  // age GATE: a user who closes the chain and goes straight for an entry is
  // still stopped. Driving the client blocker directly (the hold gesture is
  // timing-flaky — same approach as geo_hold_validation.spec.js).
  await signUpFresh(page, { contest: "world-cup-2026" });
  await expect(page.getByRole("heading", { name: /You're in/i })).toBeVisible();
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
  await page.getByRole("button", { name: /Let's go/i }).click();
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

  await expect(page.getByRole("heading", { name: /You're in/i })).toBeHidden();
  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeHidden();
  await expect(page.getByRole("heading", { name: /Verify your age/i })).toBeHidden();
  // The wallet step is the one thing still outstanding (they clicked Maybe
  // later), so IT may reopen — but nothing already satisfied may.
});
