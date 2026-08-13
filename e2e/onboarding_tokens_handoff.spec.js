const { test, expect } = require("@playwright/test");
const { reseed } = require("./helpers");

// The tokens picker must WAIT for the onboarding chain — and the chain must
// still ADVANCE while it waits.
//
// Two defects, one property. The first (found reviewing PR #296):
// showTokensPanel() only ever SWAPPED when the current modal was
// 'magic-link-welcome'; that id became unreachable, so a brand-new signup
// returning to a contest with a pending tokens step got the picker
// PLAIN-PUSHED over the chain's card. The second (found reviewing PR #302, the
// fix for the first): the chain-exit watcher polls every 300ms and counts a
// _closing card as gone, so during the ~250ms hand-off gap between two steps it
// announced the chain complete, the picker took the screen, and the NEXT chain
// step pushed on top of it — the same stacked pair, in the other order.
//
// WHY THE FIRST DRAFT OF THIS SPEC COULD NOT SEE THE SECOND DEFECT, because it
// is the whole reason this file reads the way it does: it asserted only the
// terminal state — Escape past whatever was left, then "the picker is alone."
// The healthy sequence and the raced one BOTH end at depth 1 with 'auth' on
// top, so it went green with the bug present. A spec that cannot fail on the
// bug it targets is what let this class through twice.
//
// So assert the ADVANCE, step by step: each chain card opens ALONE, with the
// picker not yet on the stack underneath it, and the driver has not yet
// announced the chain complete. Reading the STACK (not the screen) is
// load-bearing — the modal host renders only current(), so a picker stacked
// underneath is invisible to any selector-based assertion.
//
// SENSITIVITY, stated honestly: the race is ~250ms of window against a 300ms
// poll, so a single hand-off exposes it ~83% of the time. This spec crosses
// BOTH of the chain's hand-offs (first name → age, age → wallet), which takes
// detection to ~97%. On fixed code it is deterministic, not lucky: the driver
// refuses to finish while a hand-off is in flight, so the picker CANNOT be on
// the stack at either checkpoint.
//
// This lane runs ENABLE_WEB3_ONLY_ONBOARDING and ENABLE_AGE_GATE on
// (playwright.config.js), so the chain here is welcome → first name → age →
// wallet. Production runs the age gate WITHOUT web3-only, i.e. welcome → first
// name → age; both shapes take the same 250ms hand-off branch, which is the
// branch under test.
test.setTimeout(90_000);

test.beforeEach(async ({ request }) => await reseed(request));

// The LIVE stack, top last. Entries mid-close are excluded — they are already
// off the screen and about to be spliced.
async function stackIds(page) {
  return page.evaluate(() => {
    const m = window.Alpine && Alpine.store && Alpine.store("modals");
    return m ? (m.stack || []).filter((e) => e && !e._closing).map((e) => e.id) : ["<no-modal-store>"];
  });
}

async function currentId(page) {
  return page.evaluate(() => {
    const m = window.Alpine && Alpine.store && Alpine.store("modals");
    const c = m && m.current && m.current();
    return c ? c.id : null;
  });
}

// Watch the driver's OWN announcement too, so a failure names the mechanism
// ("the chain said it was over mid-hand-off") and not only the symptom.
async function recordChainCompletions(page) {
  await page.evaluate(() => {
    window.__chainCompleteCount = 0;
    window.addEventListener("onboarding-chain-complete", () => {
      window.__chainCompleteCount += 1;
    });
  });
}

async function chainCompletions(page) {
  return page.evaluate(() => window.__chainCompleteCount);
}

// The assertion this whole file exists for: the next chain step is on screen,
// it is the ONLY thing on the stack, and the chain has not been declared over.
//
// expect().toBeVisible() auto-retries; isVisible() would NOT — it ignores its
// timeout and answers for the instant it is called, which against a 250ms
// window and a mount animation is a coin toss.
async function expectStepOpenedAlone(page, id, heading) {
  await expect(page.getByRole("heading", { name: heading })).toBeVisible({ timeout: 20000 });
  expect(await currentId(page)).toBe(id);
  expect(
    await stackIds(page),
    `'${id}' must open ALONE — anything else here (typically 'auth') is the tokens picker taking the screen during the hand-off gap, with this step now stacked on top of it`
  ).toEqual([id]);
  expect(
    await chainCompletions(page),
    `the driver announced 'onboarding-chain-complete' before '${id}' opened — a chain with a hand-off in flight is not over`
  ).toBe(0);
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

// Arm the pending tokens step BEFORE the consume lands, which is the real
// sequence: the guest is on the contest, hits Get Entry Tokens, signs up, and
// returns with the step already in sessionStorage — so the chain's FIRST render
// is the one that also carries a pending picker.
//
// Setting it after the landing and reloading does NOT reproduce the bug: the
// chain prompt is one-shot (consumed server-side on that first render), so a
// reload arrives with no chain at all and the picker opens alone — a green test
// proving nothing. That is how the first draft of this spec failed.
async function signUpWithPendingTokensStep(page, prefix) {
  const email = `${prefix}-${Date.now().toString(36)}@example.com`;
  const resp = await page.request.post("/test/magic_link_token", {
    data: { email, contest: "world-cup-2026" },
  });
  expect(resp.ok()).toBeTruthy();
  const { url } = await resp.json();

  await page.goto("/contests/world-cup-2026");
  await page.evaluate(() => {
    sessionStorage.setItem(
      "pendingAuthStep",
      JSON.stringify({ step: "tokens", contestSlug: "world-cup-2026" })
    );
  });
  await page.goto(url);
  await page.waitForURL((u) => !u.pathname.startsWith("/magic_link") && !u.pathname.startsWith("/l/"));
  return email;
}

test("the chain advances through every hand-off before the picker takes the screen @smoke", async ({ page }) => {
  await signUpWithPendingTokensStep(page, "handoff");
  await recordChainCompletions(page);

  // 1. Welcome — the chain owns the screen, and it is the ONLY card up.
  await expect(page.getByRole("heading", { name: /You're in/i })).toBeVisible();
  expect(await currentId(page)).toBe("onboarding");
  expect(await stackIds(page), "the picker must not be underneath the greeting").toEqual(["onboarding"]);

  // 2. First name. Same modal, advanced in place — advance() sets _swappingOut
  //    rather than _closing, so this transition opens no watcher gap at all.
  //    That is why the bug never showed here, and why the checkpoints below are
  //    on the two MODAL-TO-MODAL edges instead.
  await page.getByRole("button", { name: /Let's go/i }).click();
  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeVisible();
  expect(await stackIds(page)).toEqual(["onboarding"]);

  // 3. HAND-OFF ONE — the first real gap: 'onboarding' closes synchronously and
  //    'age-verify' opens 250ms later.
  await page.getByRole("button", { name: "Skip for now" }).click();
  await expectStepOpenedAlone(page, "age-verify", /Verify your age/i);

  // 4. HAND-OFF TWO — the same gap on the age → wallet edge.
  await fillDob(page);
  await page.getByRole("button", { name: /Confirm & Continue/i }).click();
  await expectStepOpenedAlone(page, "wallet-setup", "Set up your wallet");

  // 5. The last step answered (declined, which still ends the chain) → NOW the
  //    picker may take the screen, alone. This is the terminal property the
  //    first draft asserted; it is kept, but it is the WEAK one — it holds in
  //    the raced sequence too, which is exactly why steps 3 and 4 exist.
  await page.getByRole("button", { name: "Maybe later" }).click();
  await page.waitForFunction(() => {
    const m = window.Alpine && Alpine.store && Alpine.store("modals");
    const c = m && m.current && m.current();
    return c && c.id === "auth";
  }, null, { timeout: 20000 });
  expect(await stackIds(page), "the picker took the screen alone, not on a pile").toEqual(["auth"]);
  await expect(page.getByRole("heading", { name: "Set up your wallet" })).toBeHidden();
  expect(await chainCompletions(page), "announced exactly once, at the end").toBe(1);
});

test("a chain the user walks away from still releases the picker", async ({ page }) => {
  // The OTHER way a chain ends, and the reason the watcher exists at all: a
  // dismissed step reports no hand-off, so a driver that only announced
  // completion on ANSWERED steps would leave the picker waiting forever — a
  // stack traded for a silence, which is worse. Escape out of the first card
  // and the picker must still arrive.
  //
  // This is also the guard on the fix: the hand-off flag must not become a way
  // for the chain to never finish.
  await signUpWithPendingTokensStep(page, "handoff-dismissed");

  await expect(page.getByRole("heading", { name: /You're in/i })).toBeVisible();
  await page.keyboard.press("Escape");

  await page.waitForFunction(() => {
    const m = window.Alpine && Alpine.store && Alpine.store("modals");
    const c = m && m.current && m.current();
    return c && c.id === "auth";
  }, null, { timeout: 20000 });
  expect(await stackIds(page)).toEqual(["auth"]);
});

test("with no chain armed the picker still opens immediately", async ({ page }) => {
  // The wait must not become a hang for everyone else: a returning user has no
  // chain, so no 'onboarding-chain-complete' is ever coming, and the board must
  // read __onboardingChainArmed and open at once.
  const email = `handoff-returning-${Date.now().toString(36)}@example.com`;
  const first = await page.request.post("/test/magic_link_token", { data: { email } });
  await page.goto((await first.json()).url);
  await page.waitForURL((u) => !u.pathname.startsWith("/magic_link") && !u.pathname.startsWith("/l/"));

  // Answer the chain so the account owes nothing, then come back as a returning
  // login with a pending tokens step.
  const letsGo = page.getByRole("button", { name: /Let's go/i });
  if (await letsGo.waitFor({ state: "visible", timeout: 8000 }).then(() => true).catch(() => false)) {
    await letsGo.click();
    const skip = page.getByRole("button", { name: "Skip for now" });
    if (await skip.waitFor({ state: "visible", timeout: 8000 }).then(() => true).catch(() => false)) {
      await skip.click();
    }
  }

  const second = await page.request.post("/test/magic_link_token", {
    data: { email, contest: "world-cup-2026" },
  });
  await page.goto((await second.json()).url);
  await page.waitForURL((u) => !u.pathname.startsWith("/magic_link") && !u.pathname.startsWith("/l/"));
  await page.evaluate(() => {
    sessionStorage.setItem(
      "pendingAuthStep",
      JSON.stringify({ step: "tokens", contestSlug: "world-cup-2026" })
    );
  });
  await page.reload();

  await page.waitForFunction(() => {
    const m = window.Alpine && Alpine.store && Alpine.store("modals");
    const c = m && m.current && m.current();
    return c && c.id === "auth";
  }, null, { timeout: 20000 });
  expect(await stackIds(page)).toEqual(["auth"]);
});
