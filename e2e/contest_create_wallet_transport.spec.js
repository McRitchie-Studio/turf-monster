// The create + bundle flows' wallet transport, in a real browser.
//
// WHAT THIS TIER ANSWERS THAT NO OTHER CAN. The node tiers drive the handlers,
// the registration and the whole round trip — but every one of them BUILDS the
// document they run in. None can show that the two intents are registered on the
// page a wallet actually returns to, which is studio-engine's view and belongs
// to neither of the pages that start these flows.
//
// That gap is the epic's most expensive one: walletOps.resume() consumes the
// journal at take() BEFORE requireHandler runs, so an intent missing there loses
// the trip with nothing left to retry — after the operator has approved.
const { test, expect } = require("@playwright/test");

const IPHONE =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

// The exact route a wallet is handed as redirect_link.
const CALLBACK = "/auth/phantom/callback";

test.describe("the page a wallet returns to", () => {
  test("registers contest_create and contest_bundle on the callback route itself @smoke", async ({ page }) => {
    // REGISTERED FROM THE LAYOUT, not from contests/new or contests/generator.
    // The callback renders studio-engine's view, which never saw either page —
    // and walletOps.resume() consumes the journal at take() BEFORE requireHandler
    // runs, so an unregistered intent here loses the contest with nothing left to
    // retry, after the operator has already approved in their wallet.
    await page.goto(CALLBACK);

    await expect
      .poll(() => page.evaluate(() => typeof window.SolanaStudio?.walletOps?.defined))
      .toBe("function");

    const registered = await page.evaluate(() => ({
      create: window.SolanaStudio.walletOps.defined("contest_create"),
      bundle: window.SolanaStudio.walletOps.defined("contest_bundle"),
    }));

    expect(registered).toEqual({ create: true, bundle: true });
  });

  test("all four handlers are callable there, not just named @smoke", async ({ page }) => {
    // `defined()` only proves a NAME was registered. A registration pointing at
    // undefined functions satisfies the assertion above and fails identically at
    // run time — on the return leg, which is the worst place to find out.
    await page.goto(CALLBACK);
    await expect.poll(() => page.evaluate(() => typeof window.tmCompleteContestCreate)).toBe("function");

    const shapes = await page.evaluate(() => ({
      prepareCreate: typeof window.tmPrepareContestCreate,
      completeCreate: typeof window.tmCompleteContestCreate,
      prepareBundle: typeof window.tmPrepareContestBundle,
      completeBundle: typeof window.tmCompleteContestBundle,
      fetch: typeof window.tmWalletFetch,
      runner: typeof window.tmWalletOp,
    }));

    expect(shapes).toEqual({
      prepareCreate: "function",
      completeCreate: "function",
      prepareBundle: "function",
      completeBundle: "function",
      fetch: "function",
      runner: "function",
    });
  });
});

// THE CODEC ITSELF IS NOT RE-TESTED HERE. e2e/free_entry_spend_mirror.spec.js
// ("the inline codec round-trips a co-signed transaction through real web3.js")
// already asks the real library both ways on a genuinely two-signer transaction,
// which is the sharper version of the same question. A second copy on a
// different page would add a lane minute and no coverage. What IS only here is
// the registration of these two intents on the callback document, above, and the
// phone's view of them, below.

test.describe("on a phone", () => {
  test.use({ userAgent: IPHONE });

  test("both intents are registered and the flow is handed a redirect provider", async ({ page }) => {
    await page.goto("/");
    await expect
      .poll(() => page.evaluate(() => typeof window.SolanaStudio?.redirectProvider?.forWallet))
      .toBe("function");

    const state = await page.evaluate(() => {
      const p = window.walletProvider.detect();
      return {
        isMobile: window.walletProvider.isMobile(),
        transport: p && p.transport,
        create: window.SolanaStudio.walletOps.defined("contest_create"),
        bundle: window.SolanaStudio.walletOps.defined("contest_bundle"),
        // The capability both flows depend on: these transactions are CO-SIGNED,
        // so the wallet must sign only and let the server broadcast.
        signsOnly: p ? !p.can("signAndSendTransaction") : null,
      };
    });

    expect(state.isMobile).toBe(true);
    expect(state.transport).toBe("redirect");
    expect(state.create).toBe(true);
    expect(state.bundle).toBe(true);
    expect(state.signsOnly).toBe(true);
  });

  test("a phone gets a provider with no inline codec, and that is correct", async ({ page }) => {
    // THE CONTROL on the inline codec. A redirect provider never sees a
    // Transaction object, so advertising the conversion on it would claim
    // something that transport can never do — and would let a caller that
    // wrongly took the inline path get further before failing.
    await page.goto("/");
    await expect
      .poll(() => page.evaluate(() => typeof window.SolanaStudio?.redirectProvider?.forWallet))
      .toBe("function");

    const codec = await page.evaluate(() => {
      const p = window.walletProvider.detect();
      return [typeof p.deserializeTransaction, typeof p.serializeTransaction];
    });

    expect(codec).toEqual(["undefined", "undefined"]);
  });
});
