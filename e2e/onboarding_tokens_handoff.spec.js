const { test, expect } = require("@playwright/test");
const { reseed } = require("./helpers");

// The tokens picker must WAIT for the onboarding chain, not open on top of it.
//
// The defect (found by Shannon reviewing PR #296): showTokensPanel() only ever
// SWAPPED when the current modal was 'magic-link-welcome'. That id became
// unreachable, so a brand-new signup returning to a contest with a pending
// tokens step got the picker PLAIN-PUSHED over the chain's card — the greeting
// lingering underneath, two cards deep, answered in the wrong order. Exactly the
// bug class PR #296 set out to fix, reintroduced three files away.
//
// WHY THIS SPEC RUNS THE FLAG OFF: it is reachable with
// ENABLE_WEB3_ONLY_ONBOARDING **off**, which is the default configuration. The
// e2e lane runs it ON (playwright.config.js), so a spec that inherited the lane
// default would never see this. Flipping a server flag per-spec is not possible,
// so this drives the client state the board actually reads.
//
// The fix is a HAND-OFF, not a swap: swapping the chain's card away would strand
// the chain (its step never reports done, so the remaining steps never open), so
// the layout announces 'onboarding-chain-complete' and the board waits for it.
test.setTimeout(60_000);

test.beforeEach(async ({ request }) => await reseed(request));

async function stackDepth(page) {
  return page.evaluate(() => {
    const m = window.Alpine && Alpine.store && Alpine.store("modals");
    return m ? (m.stack || []).filter((e) => e && !e._closing).length : -1;
  });
}

async function currentId(page) {
  return page.evaluate(() => {
    const m = window.Alpine && Alpine.store && Alpine.store("modals");
    const c = m && m.current && m.current();
    return c ? c.id : null;
  });
}

test("the tokens picker waits for the chain instead of stacking over it @smoke", async ({ page }) => {
  const email = `handoff-${Date.now().toString(36)}@example.com`;
  const resp = await page.request.post("/test/magic_link_token", {
    data: { email, contest: "world-cup-2026" },
  });
  const { url } = await resp.json();

  // Arm the pending tokens step BEFORE the consume lands, which is the real
  // sequence: the guest is on the contest, hits Get Entry Tokens, signs up, and
  // returns with the step already in sessionStorage — so the chain's FIRST
  // render is the one that also carries a pending picker.
  //
  // Setting it after the landing and reloading does NOT reproduce the bug: the
  // chain prompt is one-shot (consumed server-side on that first render), so a
  // reload arrives with no chain at all and the picker opens alone — a green
  // test proving nothing. That is how the first draft of this spec failed.
  await page.goto("/contests/world-cup-2026");
  await page.evaluate(() => {
    sessionStorage.setItem(
      "pendingAuthStep",
      JSON.stringify({ step: "tokens", contestSlug: "world-cup-2026" })
    );
  });
  await page.goto(url);
  await page.waitForURL((u) => !u.pathname.startsWith("/magic_link") && !u.pathname.startsWith("/l/"));

  // The chain owns the screen first, and it is the ONLY card on the stack.
  await expect(page.getByRole("heading", { name: /You're in/i })).toBeVisible();
  expect(await currentId(page)).toBe("onboarding");
  expect(await stackDepth(page), "the picker must not be underneath/on top yet").toBe(1);

  // Walk the chain out. Each step hands off; nothing stacks behind it.
  await page.getByRole("button", { name: /Let's go/i }).click();
  await expect(page.getByRole("heading", { name: /What should we call you/i })).toBeVisible();
  expect(await stackDepth(page)).toBe(1);
  await page.getByRole("button", { name: "Skip for now" }).click();

  // Walk the chain OUT. This lane runs both flags on, so after the name step
  // the chain still owes age + wallet; rather than pin this spec to one flag
  // combination, dismiss whatever is left — which is also the harder path,
  // because a dismissed step reports no hand-off and the waiter would hang
  // forever if the driver only announced completion on ANSWERED steps.
  for (let i = 0; i < 4; i++) {
    const id = await currentId(page);
    if (!id || id === "auth") break;
    await page.keyboard.press("Escape");
    await page.waitForTimeout(400);
  }

  // Chain gone → NOW the picker may take the screen, alone.
  await page.waitForFunction(() => {
    const m = window.Alpine && Alpine.store && Alpine.store("modals");
    const c = m && m.current && m.current();
    return c && c.id === "auth";
  }, null, { timeout: 20000 });
  expect(await stackDepth(page), "the picker took the screen alone, not on a pile").toBe(1);
  await expect(page.getByRole("heading", { name: /You're in/i })).toBeHidden();
});

test("with no chain armed the picker still opens immediately", async ({ page }) => {
  // The wait must not become a hang for everyone else: a returning user (no
  // chain) has nothing to wait for, and the picker has to open as it always did.
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
  expect(await stackDepth(page)).toBe(1);
});
