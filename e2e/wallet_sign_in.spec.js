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

  // The decline must reach the caller — solana-studio's wallet picker and
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

// ── The MOBILE return leg, and the race this app DECIDED ──────────────────
//
// adopt-engine-phantom-deeplink deleted this app's copy of
// solana_sessions/phantom_callback and now renders studio-engine's. That copy was
// a TRUE SHADOW at the identical virtual path, so for as long as it existed the
// engine's was dead code and no assertion anywhere could tell.
//
// WHY A BROWSER AND NOTHING CHEAPER. solana-studio ships
// solana_studio/_deeplink_assets, which APPENDS a script element for tweetnacl and
// is therefore ASYNCHRONOUS, while this callback reads `nacl` AT PARSE TIME and
// hard-fails with no retry. This app resolved that by keeping its own BLOCKING,
// SRI-pinned tweetnacl tag in layouts/application and rendering deeplink_assets
// nowhere. A Rails test can assert the tag carries no defer and that no view
// renders the loader — it cannot assert that `nacl` was actually DEFINED when the
// IIFE ran. Only a page load can, and the difference between the two outcomes is
// one line of runtime text.
//
// It also pins the sink this app opts back in to
// (Studio.wallet_debug_sink = -> { !AppFlags.live_production? }) and the OPSEC
// guarantee attached to it, against a REAL localStorage rather than a stubbed one.
test("the callback clears its nacl gate and never prints the dapp secret @smoke", async ({ page }) => {
  const SENTINEL = "SECRET-DO-NOT-PRINT-4f3a9c1e8b7d2065";

  // A handshake in flight, as the deep link leaves it. Without a pending step the
  // callback short-circuits before the nacl gate and this proves nothing.
  await page.addInitScript((secret) => {
    localStorage.setItem("phantom_dl_step", "signIn");
    localStorage.setItem("phantom_dl_nonce_at", String(Date.now()));
    localStorage.setItem("phantom_dl_secret", secret);
    localStorage.setItem("phantom_dl_pubkey", "PUBKEY-fine-to-print");
  }, SENTINEL);

  await page.goto("/auth/phantom/callback");
  await page.locator("#phantom-error:not(.hidden)").waitFor();

  // THE RACE, decided. Reaching the PARAMS error means execution passed the nacl
  // gate; losing the race stops three checks earlier with a different string.
  await expect(page.locator("#phantom-error")).toHaveText("Missing Phantom response parameters");
  expect(await page.evaluate(() => typeof window.nacl)).toBe("object");

  // The sink renders outside a real production deploy — this app's opt-in, in a
  // real browser rather than a stubbed predicate.
  const log = page.locator("#phantom-log");
  await expect(log).toBeVisible();

  // OPSEC: the dapp x25519 secret is a live private key. Its VALUE must never be
  // printed — not in full, and not as a prefix, because truncate() is not a
  // redactor. Asserted against the REAL localStorage the real page read.
  const printed = await log.innerText();
  expect(printed).not.toContain(SENTINEL);
  expect(printed).not.toContain(SENTINEL.slice(0, 16));

  // THE CONTROLS, without which "nothing leaked" passes against a sink that
  // prints nothing at all.
  expect(printed).toContain("PUBKEY-fine-to-print");
  expect(printed).toMatch(/redacted/);
});

// ── THE SETUP DIAGNOSIS, AND HOW NARROW IT HAS TO BE ──────────────────────
//
// uninitialized-phantom-reads-wrong (PR #571) stopped Phantom's generic
// "Unexpected error" from being read as a transaction failure, and answered the
// real case — an installed extension holding no keypair — with "Finish setting
// up your wallet ... create or import one". Correct for that case. But the catch
// it lives in wraps the WHOLE fallback, so the same sentence was also handed to
// people who demonstrably HAVE a wallet: anyone whose signMessage failed after a
// successful connect, anyone who dismissed the account-selection sheet, and
// anyone whose only problem was that OUR server did not answer.
//
// WHY THESE ARE BROWSER SPECS AND NOTHING CHEAPER. The function under test is
// inlined in application.html.erb and composes its answer from three moving
// parts — the provider's rejection, our own nonce fetch, and parseSolanaError's
// pass-through. A source scan can see that the guards are PRESENT; only a run
// can see which one answered.
//
// AND WHY NOTHING HERE TYPES THE SENTENCE OUT. Every assertion below compares
// values the page actually EMITTED against each other. A test that declares its
// own copy of the copy cannot notice the copy changing — poison the real string
// and a presence check stays green, which is exactly how #571 shipped with eight
// live mutants.

// A wallet that cannot answer at all — Phantom with no keypair in it. The
// BASELINE every spec below measures against, and the control that proves these
// narrower guards did not simply delete #571's fix.
const UNINITIALIZED = "Unexpected error";

test("a signMessage failure after connect() is not read as a missing wallet @smoke", async ({ page }) => {
  await injectFreshKeypair(page);
  await page.goto("/signin");

  const out = await page.evaluate(async (generic) => {
    const grab = async (fn) => {
      try { await fn(); return null; } catch (e) { return (e && e.message) ? e.message : String(e); }
    };
    const p = window.walletProvider.get("keypair");
    p.supportsSignIn = function () { return false; };
    const realConnect = p.connect.bind(p);

    // BASELINE — connect() never answers. The case #571 exists for, run for real
    // so the sentence under test is the one the source emits.
    p.connect = function () { return Promise.reject(new Error(generic)); };
    const setup = await grab(() => window.solanaConnectAndVerify("keypair", {}));

    // THE BUG — connect() DOES answer, with a public key, and only the signature
    // fails. The wallet has proven it holds a keypair; "create or import one" is
    // false advice to someone whose wallet just identified itself.
    let pubkey = null;
    p.connect = function () {
      return realConnect().then(function (r) { pubkey = r.publicKey.toBase58(); return r; });
    };
    p.signMessage = function () { return Promise.reject(new Error(generic)); };
    const signing = await grab(() => window.solanaConnectAndVerify("keypair", {}));

    return {
      setup,
      signing,
      pubkey,
      mapped: window.parseSolanaError(setup),
      // Both from the page's OWN mapper, never a copy typed into this spec.
      // `mappedGeneric` is what the raw wallet string BECOMES — the transaction
      // sentence this guard exists to keep off a sign-in surface.
      mappedSigning: window.parseSolanaError(signing),
      mappedGeneric: window.parseSolanaError(generic),
    };
  }, UNINITIALIZED);

  // The wallet ANSWERED. Without this the spec would pass against a connect()
  // that failed for its own reasons and never reached signMessage at all.
  expect(out.pubkey).toMatch(/^[1-9A-HJ-NP-Za-km-z]{32,44}$/);

  // #571 still works: the wallet that could not answer is still rediagnosed...
  expect(out.setup).not.toBe(UNINITIALIZED);
  // ...and the sentence survives parseSolanaError untouched, which is the
  // coupling it rests on. Asserted against what the page emitted, not a copy.
  expect(out.mapped).toBe(out.setup);

  // THE REGRESSION, IN THE VOCABULARY THE USER ACTUALLY READS. Asserting the RAW
  // rethrow was not enough, and that gap is why this defect survived a green
  // suite: every surface runs parseSolanaError before painting, so a raw string
  // that reads fine can still be MAPPED into the wrong sentence. It was —
  // "Unexpected error" became "…Check wallet connection and USDC balance." for a
  // signed-out user who attempted no transaction.
  //
  // THE PRECONDITION FIRST, or the control below is vacuous. The raw generic
  // really is rewritten by the mapper; without this, "not that sentence" could
  // pass by comparing against a string nothing on this page ever produces.
  expect(out.mappedGeneric).not.toBe(UNINITIALIZED);

  // THE CONTROL. What the signing path emits must not land on the transaction
  // sentence — compared against the page's own mapper OUTPUT, so rewording the
  // mapper cannot quietly make this pass.
  expect(out.mappedSigning).not.toBe(out.mappedGeneric);
  // ...and it survives the mapper untouched, the same coupling `setup` rests on.
  expect(out.mappedSigning).toBe(out.signing);
  // Still its own diagnosis, and no longer the wallet's bare generic.
  expect(out.signing).not.toBe(out.setup);
  expect(out.signing).not.toBe(UNINITIALIZED);
});

test("a wallet that authorized no account is not read as a missing wallet @smoke", async ({ page }) => {
  // TWO Wallet Standard wallets through the SAME adapter, differing only in how
  // standard:connect answers. Resolving an EMPTY accounts array is a user who
  // dismissed the account-selection sheet or deselected every account —
  // wallet_provider.js rejects that with "No account authorized", and the
  // fallback used to rewrite it into setup copy for someone who plainly has one.
  await page.addInitScript(() => {
    const shell = (name, connect) => ({
      name,
      version: "1.0.0",
      icon: "data:image/svg+xml;base64,PHN2Zy8+",
      chains: ["solana:devnet"],
      accounts: [],
      features: {
        "standard:connect": { version: "1.0.0", connect },
        "solana:signMessage": {
          version: "1.0.0",
          signMessage: async () => [{ signature: new Uint8Array(64) }]
        }
      }
    });
    const wallets = [
      // The sheet was dismissed: the wallet answered, and authorized nothing.
      shell("SheetDismissed", async () => ({ accounts: [] })),
      // The control — a wallet with nothing in it, which SHOULD get setup copy.
      shell("NoKeypairHere", async () => { throw new Error("Unexpected error"); })
    ];
    window.addEventListener("wallet-standard:app-ready", (e) => {
      try { wallets.forEach((w) => e.detail.register(w)); } catch (err) { /* unregistered */ }
    });
  });
  await page.goto("/signin");

  const out = await page.evaluate(async () => {
    const grab = async (fn) => {
      try { await fn(); return null; } catch (e) { return (e && e.message) ? e.message : String(e); }
    };
    return {
      named: window.walletProvider.available().map((w) => w.name),
      empty: await grab(() => window.solanaConnectAndVerify("SheetDismissed", {})),
      setup: await grab(() => window.solanaConnectAndVerify("NoKeypairHere", {}))
    };
  });

  // Both fakes really registered and really went through the Wallet Standard
  // adapter. Without this the spec could be comparing two nulls.
  expect(out.named).toEqual(expect.arrayContaining(["SheetDismissed", "NoKeypairHere"]));

  // The control: a wallet that cannot answer still gets the setup sentence.
  expect(out.setup).not.toBe(UNINITIALIZED);

  // THE REGRESSION. Opaque, but TRUE — and not the readable sentence that lies.
  expect(out.empty).toBe("No account authorized");
  expect(out.empty).not.toBe(out.setup);
});

test("the nonce round trip runs against the open wallet prompt @smoke", async ({ page }) => {
  // Closing #571's first blocker hoisted `await noncePromise` above the try,
  // which put a server round trip AHEAD of the wallet sheet for every wallet
  // without solana:signIn. The await belongs BELOW connect(), where the fetch
  // overlaps the human reading the prompt; tagging the fetch's own rejection is
  // what makes that safe. Only ORDER can witness it, so order is what is pinned.
  await injectFreshKeypair(page);
  await page.goto("/signin");

  const out = await page.evaluate(async () => {
    const order = [];
    const realFetch = window.fetch.bind(window);
    let release = null;
    let seen = false;
    window.fetch = function (url, opts) {
      if (!seen && String(url).indexOf("/auth/solana/nonce") !== -1) {
        seen = true;
        order.push("nonce:requested");
        return new Promise(function (resolve) {
          release = function () { order.push("nonce:answered"); resolve(realFetch(url, opts)); };
        });
      }
      return realFetch(url, opts);
    };

    const p = window.walletProvider.get("keypair");
    p.supportsSignIn = function () { return false; };
    const realConnect = p.connect.bind(p);
    p.connect = function () { order.push("connect:called"); return realConnect(); };

    const pending = window.solanaConnectAndVerify("keypair", {});
    // Hold the nonce response back. If the await sits above connect(), nothing
    // reaches the wallet until this is released, and the order inverts.
    await new Promise((r) => setTimeout(r, 250));
    release();
    const result = await pending;
    window.fetch = realFetch;
    return { order, success: !!(result && result.success) };
  });

  expect(out.order).toEqual(["nonce:requested", "connect:called", "nonce:answered"]);
  // And the reordering still signs the user in — the half a pure ordering
  // assertion is blind to.
  expect(out.success).toBe(true);
});

test("our own server failing is not read as a missing wallet @smoke", async ({ page }) => {
  await injectFreshKeypair(page);
  await page.goto("/signin");

  const out = await page.evaluate(async (generic) => {
    const grab = async (fn) => {
      try { await fn(); return null; } catch (e) { return (e && e.message) ? e.message : String(e); }
    };
    const p = window.walletProvider.get("keypair");
    p.supportsSignIn = function () { return false; };
    const realConnect = p.connect.bind(p);

    // BASELINE, with the real endpoint up.
    p.connect = function () { return Promise.reject(new Error(generic)); };
    const setup = await grab(() => window.solanaConnectAndVerify("keypair", {}));

    // Now /auth/solana/nonce falls over, with a wallet that works perfectly.
    p.connect = realConnect;
    const realFetch = window.fetch.bind(window);
    window.fetch = function (url, opts) {
      if (String(url).indexOf("/auth/solana/nonce") !== -1) {
        return Promise.reject(new TypeError("Failed to fetch"));
      }
      return realFetch(url, opts);
    };
    const serverDown = await grab(() => window.solanaConnectAndVerify("keypair", {}));
    window.fetch = realFetch;
    return { setup, serverDown };
  }, UNINITIALIZED);

  // "Failed to fetch" is the one string that says OFFLINE. Wrapping it would
  // replace the browser's own diagnosis with our guess, so it must arrive
  // verbatim — and above all it must not be the setup sentence.
  expect(out.serverDown).toBe("Failed to fetch");
  expect(out.serverDown).not.toBe(out.setup);
  expect(out.setup).not.toBe(UNINITIALIZED);
});
