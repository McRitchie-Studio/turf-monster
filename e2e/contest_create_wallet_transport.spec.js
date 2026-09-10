// The create + bundle flows' wallet transport, in a real browser.
//
// WHAT THIS TIER ANSWERS THAT NO OTHER CAN. The node tiers drive the handlers,
// the registration and the whole round trip — but every one of them STUBS
// solanaWeb3. None can show that the inline provider's transaction codec works
// against the REAL @solana/web3.js the page loads, or that the two intents are
// registered on the document a wallet actually returns to.
//
// The codec is the piece that made ONE call site possible: walletOps hands every
// transport the same base58 wire bytes, an injected wallet signs a Transaction
// OBJECT, and the provider owns the conversion in both directions. A codec that
// is subtly wrong fails at the wallet, one page death away from the handler that
// caused it.
const { test, expect } = require("@playwright/test");

const IPHONE =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

// The exact route a wallet is handed as redirect_link.
const CALLBACK = "/auth/phantom/callback";

// Enough of an injected wallet for detect() to return the inline PhantomProvider.
// The codec never calls the wallet, so nothing beyond isPhantom is needed.
async function injectInlineWallet(page) {
  await page.addInitScript(() => {
    window.phantom = { solana: { isPhantom: true, connect() {}, signTransaction(tx) { return Promise.resolve(tx); } } };
  });
}

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

test.describe("the inline transaction codec, against the real web3.js", () => {
  test.beforeEach(async ({ page }) => {
    await injectInlineWallet(page);
    await page.goto("/");
    await expect.poll(() => page.evaluate(() => typeof window.solanaWeb3?.Transaction)).toBe("function");
    await expect
      .poll(() => page.evaluate(() => typeof window.SolanaStudio?.walletTransport?.base58?.encode))
      .toBe("function");
  });

  test("a REAL transaction survives the base58 round trip byte for byte", async ({ page }) => {
    const result = await page.evaluate(() => {
      // A real, buildable transaction: the system program moving one lamport.
      const key = new solanaWeb3.PublicKey("11111111111111111111111111111111");
      const tx = new solanaWeb3.Transaction();
      tx.feePayer = key;
      tx.recentBlockhash = "11111111111111111111111111111111";
      tx.add(solanaWeb3.SystemProgram.transfer({ fromPubkey: key, toPubkey: key, lamports: 1 }));

      const wire = tx.serialize({ requireAllSignatures: false, verifySignatures: false });
      const b58 = window.SolanaStudio.walletTransport.base58.encode(new Uint8Array(wire));

      const provider = window.walletProvider.detect();
      const rebuilt = provider.deserializeTransaction(b58);
      const backToWire = provider.serializeTransaction(rebuilt);

      return {
        providerName: provider && provider.name,
        isTransaction: rebuilt instanceof solanaWeb3.Transaction,
        roundTripped: backToWire === b58,
        instructions: rebuilt.instructions.length,
      };
    });

    expect(result.providerName).toBe("phantom");
    // AN OBJECT, because that is what an injected wallet's signTransaction takes.
    // Hand it the base58 string walletOps carries and it throws
    // "t.serialize is not a function" from inside the extension's own code.
    expect(result.isTransaction).toBe(true);
    expect(result.instructions).toBe(1);
    // THE ONE RIGHT ANSWER: the same bytes, not merely "a string came back".
    // complete() posts these to the server, which cosigns exactly them.
    expect(result.roundTripped).toBe(true);
  });

  test("the co-sign serialize options are load-bearing, and this browser proves it", async ({ page }) => {
    // THE MUTATION, RUN LIVE. Every transaction this app sends is PARTIALLY
    // signed on purpose — the admin slot is empty and the server fills it — so a
    // plain .serialize() asserts every required signature is present and THROWS.
    // A codec that dropped the options would fail here, in the browser, exactly
    // as it fails for a user.
    const result = await page.evaluate(() => {
      const key = new solanaWeb3.PublicKey("11111111111111111111111111111111");
      const tx = new solanaWeb3.Transaction();
      tx.feePayer = key;
      tx.recentBlockhash = "11111111111111111111111111111111";
      tx.add(solanaWeb3.SystemProgram.transfer({ fromPubkey: key, toPubkey: key, lamports: 1 }));

      let plainThrew = false;
      try {
        tx.serialize();
      } catch (e) {
        plainThrew = true;
      }

      let codecThrew = false;
      try {
        window.walletProvider.detect().serializeTransaction(tx);
      } catch (e) {
        codecThrew = true;
      }

      return { plainThrew, codecThrew };
    });

    expect(
      result.plainThrew,
      "precondition: an unsigned transaction cannot be serialized with signature checks on"
    ).toBe(true);
    expect(
      result.codecThrew,
      "the provider codec must serialize the very transactions a plain .serialize() refuses"
    ).toBe(false);
  });
});

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
    // THE CONTROL on the codec suite above. A redirect provider never sees a
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
