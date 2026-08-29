const { test, expect } = require("@playwright/test");
const nacl = require("tweetnacl");
const { reseed } = require("./helpers");

// Consolidated wallet sign-in. `solana:signIn` collapses connect + signMessage
// into ONE wallet approval; wallets without the feature keep the two-step path.
//
// WHY THE KEYPAIR PROVIDER ADVERTISES signIn: without it this whole feature
// would ship with zero browser coverage. Every test provider would take the
// fallback branch and the new code would never execute in CI — the exact shape
// of rot config/feature_shapes.yml's header warns about. So the mock implements
// signIn, and the fallback is exercised by explicitly switching it back off.
//
// Uses a FRESHLY GENERATED keypair per test rather than e2e/keypair-provider.js,
// which needs SOLANA_BOT_KEY and is devnet-nightly only. A fresh wallet has no
// user row, so each run exercises the create-or-login signup side.

async function injectFreshKeypair(page) {
  const kp = nacl.sign.keyPair();
  await page.addInitScript((bytes) => {
    window.__WALLET_KEYPAIR_SECRET = new Uint8Array(bytes);
  }, Array.from(kp.secretKey));
  return kp;
}

test.beforeEach(async ({ request }) => await reseed(request));

test("the keypair provider advertises signIn and returns the normalized shape @smoke", async ({ page }) => {
  await injectFreshKeypair(page);
  await page.goto("/signin");

  const supports = await page.evaluate(() =>
    window.walletProvider.get("keypair").supportsSignIn()
  );
  expect(supports).toBe(true);

  const out = await page.evaluate(async () => {
    const p = window.walletProvider.get("keypair");
    const o = await p.signIn({
      domain: window.location.host,
      statement: "Sign in to Turf Monster",
      nonce: "e2etestnonce0001",
    });
    return {
      address: o.address,
      text: new TextDecoder().decode(o.signedMessage),
      sigLen: o.signature.length,
    };
  });

  // The contract solanaConnectAndVerify depends on: an address, the exact bytes
  // signed, and a 64-byte Ed25519 signature.
  expect(out.address).toMatch(/^[1-9A-HJ-NP-Za-km-z]{32,44}$/);
  expect(out.sigLen).toBe(64);
  expect(out.text).toContain("Nonce: e2etestnonce0001");
  expect(out.text).toContain("wants you to sign in with your Solana account:");
  expect(out.text).toContain(out.address);
});

test("signIn path signs a fresh wallet in with one approval @smoke", async ({ page }) => {
  await injectFreshKeypair(page);
  await page.goto("/signin");

  const result = await page.evaluate(() => window.solanaConnectAndVerify("keypair", {}));
  expect(result.success).toBe(true);

  // Session actually established, not just a 200.
  const state = await page.evaluate(async () => {
    const r = await fetch("/account/session_state", { headers: { Accept: "application/json" } });
    return r.json();
  });
  expect(state.loggedIn).toBe(true);
  expect(state.mode).toBe("web3");
});

// The two halves of the try -> catch -> fallback transition. A DECLINE is not an
// INCAPABILITY: the fallback exists for wallets that cannot do signIn, never for
// a human who will not. Swallowing the rejection asks a user who just said no to
// connect, and then to sign — three prompts in the change whose whole purpose is
// to ask once. Only a browser can witness which branch ran, because both post
// the identical params to the identical endpoint.

test("a declined signIn propagates instead of re-prompting through the fallback @smoke", async ({ page }) => {
  await injectFreshKeypair(page);
  await page.goto("/signin");

  const outcome = await page.evaluate(async () => {
    const p = window.walletProvider.get("keypair");
    let connectCalls = 0;
    const realConnect = p.connect.bind(p);
    p.connect = function () { connectCalls += 1; return realConnect(); };

    // Phantom rejects a declined SIWS prompt with code 4001.
    p.signIn = function () {
      const err = new Error("User rejected the request.");
      err.code = 4001;
      return Promise.reject(err);
    };

    let rejected = false;
    let message = null;
    try {
      await window.solanaConnectAndVerify("keypair", {});
    } catch (e) {
      rejected = true;
      message = (e && e.message) || String(e);
    }
    return { rejected, message, connectCalls };
  });

  // The decline must reach the caller — studio-engine's wallet picker and
  // modals/_wallet_setup both render "Signature rejected" off exactly this.
  expect(outcome.rejected).toBe(true);
  expect(outcome.message).toMatch(/rejected/i);
  // And the user must NOT be asked a second or third time.
  expect(outcome.connectCalls).toBe(0);
});

test("a non-conforming signIn message still falls back to connect + signMessage @smoke", async ({ page }) => {
  await injectFreshKeypair(page);
  await page.goto("/signin");

  const outcome = await page.evaluate(async () => {
    const p = window.walletProvider.get("keypair");
    let connectCalls = 0;
    const realConnect = p.connect.bind(p);
    p.connect = function () { connectCalls += 1; return realConnect(); };

    const realSignIn = p.signIn.bind(p);
    // A wallet that composes its own message and drops our nonce. The audit must
    // catch it BEFORE posting and spend a second prompt rather than hand the
    // server a message it will reject with a hard 401.
    p.signIn = async function (input) {
      const real = await realSignIn(input);
      const text = new TextDecoder().decode(real.signedMessage).replace(/\nNonce: .*/, "");
      return {
        address: real.address,
        signedMessage: new TextEncoder().encode(text),
        signature: real.signature,
      };
    };

    const result = await window.solanaConnectAndVerify("keypair", {});
    return { success: !!(result && result.success), connectCalls };
  });

  // This is the side the fix must NOT break: a genuine incapability still falls
  // back, and the fallback still signs the user in.
  expect(outcome.success).toBe(true);
  expect(outcome.connectCalls).toBe(1);
});

test("falls back to connect + signMessage when the wallet has no signIn @smoke", async ({ page }) => {
  await injectFreshKeypair(page);
  await page.goto("/signin");

  // Switch the feature off at the provider, exactly as a wallet that never
  // implemented it would present, and confirm the old two-step path still works.
  const result = await page.evaluate(() => {
    window.walletProvider.get("keypair").supportsSignIn = function () { return false; };
    return window.solanaConnectAndVerify("keypair", {});
  });
  expect(result.success).toBe(true);

  const state = await page.evaluate(async () => {
    const r = await fetch("/account/session_state", { headers: { Accept: "application/json" } });
    return r.json();
  });
  expect(state.loggedIn).toBe(true);
  expect(state.mode).toBe("web3");
});
