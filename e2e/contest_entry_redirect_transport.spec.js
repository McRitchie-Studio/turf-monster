// The redirect transport, reachable in a real browser.
//
// WHAT THIS TIER ANSWERS THAT NO OTHER CAN. The node tiers drive the handlers,
// the registration and the whole round trip — but every one of them CONSTRUCTS
// the redirect provider by hand. None can show that a real page, loading the
// real gem assets through sprockets, actually HANDS the entry flow a redirect
// provider when a phone asks for one.
//
// That gap was not hypothetical: until this commit `detect()` could not return a
// redirect provider at all, so the branch in _turf_totals_board was dead code
// and every node test passed over it.
const { test, expect } = require("@playwright/test");

const IPHONE =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

async function walletState(page) {
  await expect
    .poll(() => page.evaluate(() => typeof window.SolanaStudio?.redirectProvider?.forWallet))
    .toBe("function");

  return page.evaluate(() => {
    const p = window.walletProvider.detect();
    return {
      isMobile: window.walletProvider.isMobile(),
      transport: p && p.transport,
      wallet: p && p.key,
      // The capability the entry flow depends on: this contest is CO-SIGNED, so
      // the wallet must sign only and let the server broadcast.
      signsOnly: p ? !p.can("signAndSendTransaction") : null,
      intentRegistered: !!(window.SolanaStudio.walletOps && window.SolanaStudio.walletOps.defined("contest_entry")),
    };
  });
}

test.describe("on a phone", () => {
  test.use({ userAgent: IPHONE });

  test("the entry flow is handed a redirect provider, not null @smoke", async ({ page }) => {
    await page.goto("/");

    const s = await walletState(page);

    expect(s.isMobile).toBe(true);
    // THE REGRESSION THIS PINS: before the detect() change this was null, the
    // branch was unreachable, and mobile entry could only ever show a message.
    expect(s.transport).toBe("redirect");
    expect(s.wallet).toBe("phantom");
    // Phantom deprecated its send-side deeplink, so signingHop falls to
    // signTransaction — which is exactly what a co-signed entry needs.
    expect(s.signsOnly).toBe(true);
  });

  test("the contest_entry intent is registered by the name the callback looks up", async ({ page }) => {
    await page.goto("/");
    const s = await walletState(page);

    // The intent is registered by the BOARD partial, so this also proves the
    // board rendered and its registration IIFE ran on a real contest page.
    expect(s.intentRegistered).toBe(true);
  });
});

test("a desktop with no extension is NOT given a redirect provider", async ({ page }) => {
  // The redirect transport answers a phone's problem. A desktop with no wallet
  // has a different remedy — install one — and handing it a deeplink would send
  // someone to a mobile app store from a laptop.
  await page.goto("/");
  const s = await walletState(page);

  expect(s.isMobile).toBe(false);
  expect(s.transport).not.toBe("redirect");
});
