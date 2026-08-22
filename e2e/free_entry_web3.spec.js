const { test, expect } = require("@playwright/test");

// The free-entry CTA, in a real browser (task: hold-for-free-entry).
//
// The board's hold button names the funding the entry will use, bound to
// $store.session.tokensAvailable. Two claims only a browser can settle: Alpine
// actually swaps the copy on BOTH buttons, and the shipped eligibilityBlocker
// treats a token as funding for a Phantom wallet — the change that made the copy
// true for web3 rather than merely broad (PR #386 blocker).
//
// Deliberately free of the 6-pick flow: the CTA's copy lives in the DOM whether
// or not the button is revealed, and the pick sequence is the known-flaky part of
// this suite (see the .fixme notes in onchain.spec.js).

const CONTEST_PATH = "/contests/nfl-2026-weeks-1-3";

async function idleLabels(page) {
  return page.$$eval(".hold-btn .hold-text li:nth-child(1)", (els) =>
    els.map((e) => e.textContent.trim())
  );
}

async function setTokens(page, count) {
  await page.evaluate((n) => {
    Alpine.store("session").tokensAvailable = n;
  }, count);
  await page.waitForTimeout(200);
}

test("the CTA names the funding, and both buttons agree", async ({ page }) => {
  await page.goto(CONTEST_PATH);
  await page.waitForFunction(() => window.Alpine && Alpine.store && Alpine.store("session"));

  // No token — the entry costs money, and the button says the neutral thing.
  await setTokens(page, 0);
  const broke = await idleLabels(page);
  expect(broke.length).toBeGreaterThanOrEqual(2);
  expect(new Set(broke)).toEqual(new Set(["Hold to Confirm"]));

  // A token in the wallet — the entry spends it, and the button says so.
  await setTokens(page, 1);
  expect(new Set(await idleLabels(page))).toEqual(new Set(["Hold for Free Entry"]));

  // Spent — the promise is withdrawn the moment it stops being true. This is the
  // case a server-rendered label gets wrong on a second entry in one page view.
  await setTokens(page, 0);
  expect(new Set(await idleLabels(page))).toEqual(new Set(["Hold to Confirm"]));
});

test("a Phantom wallet holding a token is not blocked for having no balance", async ({ page }) => {
  await page.goto(CONTEST_PATH);
  await page.waitForFunction(() => typeof window.eligibilityBlocker === "function");

  const verdicts = await page.evaluate(() => {
    const web3 = (over) =>
      Object.assign(
        { loggedIn: true, mode: "web3", usdcCents: 0, usdtCents: 0, tokensAvailable: 0 },
        over
      );
    const fee = 1900;
    return {
      // Before this task the web3 branch consulted USDC/USDT only, so this wallet
      // was told "insufficient_balance" right after reading "Hold for Free Entry".
      withToken: window.eligibilityBlocker(web3({ tokensAvailable: 1 }), fee),
      withoutToken: window.eligibilityBlocker(web3({}), fee),
      // Parity check: the managed path has always counted tokens as funding.
      web2WithToken: window.eligibilityBlocker(
        { loggedIn: true, mode: "web2", usdcCents: 0, tokensAvailable: 1, web2UsdcEntry: true },
        fee
      ),
    };
  });

  expect(verdicts.withToken).toBeNull();
  expect(verdicts.web2WithToken).toBeNull();
  expect(verdicts.withoutToken).toMatchObject({ reason: "insufficient_balance" });
});
