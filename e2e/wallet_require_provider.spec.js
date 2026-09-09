// The mobile wallet guard, in a real browser.
//
// WHAT THIS TIER ADDS. test/lib/wallet_require_provider_js_test.rb drives the
// same module under node and owns the copy rules; test/integration/
// wallet_stub_parity_test.rb proves the inlined stub agrees with it. Neither can
// answer whether the module ARRIVES — whether the importmap actually delivers
// wallet_provider.js to a real page and the method is reachable there. A pin
// dropped from importmap.rb, an asset that 404s, a syntax error a node eval
// tolerated: each leaves the page throwing "requireProvider is not a function"
// with both other tiers still green.
//
// And it is the only tier that sees a browser with genuinely no wallet, which is
// every phone that is not inside a wallet app's own browser.
const { test, expect } = require("@playwright/test");

const IPHONE =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

// Ask the REAL page's module what it does with no wallet present. Returns the
// thrown message rather than asserting inside the page, so a failure reports the
// sentence a user would have seen.
async function refusal(page) {
  return page.evaluate(() => {
    // isMobile on BOTH branches. It used to be reported only from the catch,
    // which was invisible while every mobile case threw — and became undefined
    // the moment a phone started getting a provider instead of a refusal.
    const isMobile = window.walletProvider.isMobile();
    try {
      window.walletProvider.requireProvider();
      return { threw: false, isMobile: isMobile };
    } catch (e) {
      return { threw: true, message: e.message, isMobile: isMobile };
    }
  });
}

test.describe("wallet guard on a device with no wallet", () => {
  test.describe("on a phone", () => {
    test.use({ userAgent: IPHONE });

    // SUPERSEDED, DELIBERATELY, and the rename says so. This test asserted that a
    // phone with no injected wallet is REFUSED with "open this page in your
    // wallet app" — correct when that was the only honest answer, because there
    // was no way to sign from mobile Safari at all.
    //
    // There is now. detect() returns a redirect provider on a phone once
    // solana_studio/redirect_provider.js is loaded, so the flow hands the entry
    // to the wallet app instead of apologising. Refusing here would be the
    // regression now.
    //
    // WHAT SURVIVES UNCHANGED is the thing this file was written for: whatever
    // happens, a phone must never see a raw null dereference. That assertion
    // moves down rather than being dropped.
    test("is handed a redirect provider rather than refused @smoke", async ({ page }) => {
      await page.goto("/");
      // Poll on get(), NOT requireProvider(): this change MIRRORS
      // requireProvider into the inlined stub, so polling on it is satisfied
      // by the stub and every assertion below would pass with the importmap
      // pin deleted — the one failure this tier claims to be the only one to
      // catch. get() exists only on the module.
      await expect
        .poll(() => page.evaluate(() => typeof window.walletProvider?.get))
        .toBe("function");

      const result = await refusal(page);

      expect(result.isMobile).toBe(true);
      // A path exists now, so requireProvider RESOLVES. Being refused here would
      // mean the redirect transport never reached the flow.
      expect(result.threw).toBe(false);

      const transport = await page.evaluate(() => window.walletProvider.detect()?.transport);
      expect(transport).toBe("redirect");
    });

    test("never shows a raw null dereference, whatever it decides @smoke", async ({ page }) => {
      // THE ORIGINAL POINT OF THIS FILE, kept: on 2026-09-07 a production user
      // read `null is not an object (evaluating 'provider.connect')` out of a
      // transaction modal. Whether the answer is a provider or a refusal, it must
      // never be that.
      await page.goto("/");
      await expect
        .poll(() => page.evaluate(() => typeof window.walletProvider?.get))
        .toBe("function");

      const message = await page.evaluate(() => {
        try {
          window.walletProvider.requireProvider();
          return window.walletProvider.noWalletMessage();
        } catch (e) {
          return e.message;
        }
      });

      expect(message).not.toMatch(/is not an object/i);
      expect(message).not.toMatch(/\bnull\b/i);
      expect(message).not.toMatch(/undefined/i);
    });
  });

  test("a desktop browser gets extension advice instead", async ({ page }) => {
    await page.goto("/");
    await expect
      .poll(() => page.evaluate(() => typeof window.walletProvider?.get))
      .toBe("function");

    const result = await refusal(page);

    expect(result.threw).toBe(true);
    expect(result.isMobile).toBe(false);
    expect(result.message).toMatch(/extension/i);
  });
});
