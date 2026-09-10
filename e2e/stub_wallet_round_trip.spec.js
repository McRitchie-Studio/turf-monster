// THE ROUND TRIP, JUDGED FROM THE WALLET'S SIDE.
//
// WHAT THIS FILE IS FOR, and it is a class of defect rather than an instance.
// Three bugs in the mobile-wallet epic reached a real phone before anything went
// red — the contest_entry intent unregistered on the callback page, a provider
// `detect()` would not hand a phone, and a signing deeplink with no
// `redirect_link` — and EVERY test in this area missed all three. Not through
// carelessness: they construct the provider by hand, feed it options they supply
// themselves, and never look at what a wallet would actually RECEIVE.
//
// So this spec never constructs a provider, never supplies a return leg, and
// never asserts on an object. It starts a real trip on a real page, and then
// e2e/stub-wallet.js stands where Phantom stands: it takes the universal link,
// judges it against Phantom's published parameter table, decrypts the payload
// with the dapp key THE URL CARRIES, and answers by redirecting to THE
// `redirect_link` THE URL CARRIES. A malformed deeplink therefore does not
// merely fail an assertion — it strands the trip, exactly as it strands a user.
//
// WHERE EVERY EXPECTATION COMES FROM is recorded per-entry in e2e/stub-wallet.js's
// CONTRACT table, each with a `source` and a `confidence`. The short version:
// the required/forbidden parameter sets and the response keys are VENDOR (read
// from docs.phantom.com on 2026-09-09); the x25519 key exchange is VENDOR; the
// 24-byte nonce and nacl.box envelope are inferred from the library Phantom's
// docs nominate, because the docs themselves do not state them.
//
// WHAT THIS LANE CANNOT DO, said plainly rather than left for someone to
// discover: playwright.config.js declares chromium only — there is no webkit
// project — so "on a phone" here is a USER-AGENT SWAP ON A DESKTOP ENGINE. It
// proves the protocol, the wiring and the return leg. It does not prove iOS
// Safari's storage behaviour, an OS app-switch, or that Phantom itself accepts
// these URLs. Only a device does that.
const { test, expect } = require("@playwright/test");
const { installStubWallet, decodeBase58, SIGNATURE_STUB } = require("./stub-wallet");

const IPHONE =
  "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";

// The route the wallet is told to come back to — this app's own, still drawn
// here rather than by the engine.
const CALLBACK = "/auth/phantom/callback";

// base64 for bytes [1,2,3,4,5]: small, and recognisable once it has been through
// the base64 -> base58 -> wallet -> base58 -> base64 loop the flow really runs.
const SERIALIZED_TX_B64 = "AQIDBAU=";

// Stub ONLY the two server hops. Everything between them — the deeplink, the
// crypto, the journal, the page death, the callback route, the intent lookup —
// is the real thing.
async function stubServerHops(context, seen) {
  await context.route("**/contests/*/prepare_entry", (route) => {
    seen.prepare = JSON.parse(route.request().postData() || "{}");
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        success: true,
        serialized_tx: SERIALIZED_TX_B64,
        ptx_slug: "ptx-stub-1",
        entry_id: 4242,
        entry_pda: "EntryPdaStub111111111111111111111111111111",
        token_funded: true,
      }),
    });
  });

  await context.route("**/contests/*/confirm_onchain_entry", (route) => {
    seen.confirm = JSON.parse(route.request().postData() || "{}");
    route.fulfill({
      status: 200,
      contentType: "application/json",
      body: JSON.stringify({
        success: true,
        tx_signature: "CosignedByTheServer1111111111111111111111111",
        redirect: "/contests",
      }),
    });
  });
}

// Start the trip the way the contest board starts it: the provider this browser
// really resolves, and the three options the board really passes
// (app/views/contests/_turf_totals_board.html.erb). Fire-and-forget, because
// run() ends by destroying this document.
async function startEntryTrip(page) {
  await page.waitForFunction(
    () => !!(window.walletProvider && window.SolanaStudio &&
             window.SolanaStudio.walletOps &&
             window.SolanaStudio.walletOps.defined("contest_entry"))
  );
  await page.evaluate(() => {
    // requireProvider(), not a hand-built object. On a phone with nothing
    // injected this is the ONLY thing that can hand back a redirect provider,
    // and when it could not, the mobile entry branch was dead code.
    var provider = window.walletProvider.requireProvider();
    window.__trip = window.SolanaStudio.walletOps.run(
      "contest_entry",
      { contestId: 1, csrfToken: "stub-csrf", currency: "usdc" },
      {
        provider: provider,
        appUrl: window.location.origin,
        redirectLink: window.location.origin + "/auth/phantom/callback",
        cluster: document.body.dataset.solanaCluster,
      }
    ).catch(function (e) { /* the page is on its way to the wallet */ });
  });
}

test.describe("a stub wallet on the redirect transport", () => {
  test.use({ userAgent: IPHONE });

  test("completes the contest-entry round trip @smoke", async ({ page, context }) => {
    const wallet = await installStubWallet(context);
    const seen = {};
    await stubServerHops(context, seen);

    await page.goto("/");
    await startEntryTrip(page);

    // THE LANDING. The intent's complete() returns the server's payload and
    // studio-engine's callback sends the browser to `value.redirect`. Waiting on
    // that URL is waiting on the WHOLE trip: connect, page death, callback,
    // resume, sign, page death, callback, resume, handler, server, redirect.
    await page.waitForURL((url) => url.pathname === "/contests", { timeout: 25_000 });

    // 1. The wallet was asked for exactly the two hops a cold session takes, in
    //    order. A third hop means something retried; a first hop of
    //    signAndSendTransaction means the co-signed guard slipped.
    expect(wallet.methods()).toEqual(["connect", "signTransaction"]);

    // 2. Nothing the wallet received breached Phantom's documented contract.
    //    This is the assertion that would have caught the missing redirect_link,
    //    and its message names the parameter and the vendor page.
    expect(wallet.violations).toEqual([]);

    // 3. The wallet really decrypted our payload, and it carried the session
    //    THIS wallet issued one page-death earlier. A shared secret rebuilt from
    //    the wrong key, or a session that did not survive the journal, fails here.
    const signHop = wallet.hop("signTransaction");
    expect(signHop.payload.session).toBe(wallet.session);

    // 4. The bytes the server prepared reached the wallet. base64 "AQIDBAU=" is
    //    [1,2,3,4,5]; the flow converts it to base58 before it goes out.
    expect(Array.from(decodeBase58(signHop.payload.transaction))).toEqual([1, 2, 3, 4, 5]);

    // 5. THE RETURN LEG, which is the half every previous test supplied for
    //    itself: the bytes the WALLET produced are the bytes the SERVER
    //    received. Asserted as the CONCATENATION the wallet built — its 64-byte
    //    signature followed by the transaction the server prepared — so a
    //    truncation, a re-encode, or a swapped payload cannot pass.
    const received = Buffer.from(seen.confirm.signed_tx, "base64");
    expect(Array.from(received.subarray(0, 64))).toEqual(Array.from(SIGNATURE_STUB));
    expect(Array.from(received.subarray(64))).toEqual([1, 2, 3, 4, 5]);
    expect(seen.confirm.signed_tx).toBe(
      Buffer.from(decodeBase58(wallet.signedTransactions[0])).toString("base64")
    );

    // 6. …carrying the state prepare() minted, across two page deaths.
    expect(seen.confirm.ptx_slug).toBe("ptx-stub-1");
    expect(seen.confirm.entry_id).toBe(4242);
    expect(seen.prepare.currency).toBe("usdc");
  });

  test("hands every hop a redirect_link Phantom would accept", async ({ page, context }) => {
    // THE NAMED TEST FOR THE THIRD DEFECT, deliberately separate from the round
    // trip above so a red run says WHICH parameter and on WHICH hop rather than
    // "the trip did not finish".
    //
    // The signing hop is the one that was broken: walletOps builds it inside
    // resume() as `opts.redirectLink || journal.redirectLink`, studio-engine's
    // callback passes no redirectLink, and redirect_provider journals none — so
    // the parameter was simply omitted, and Phantom's signTransaction page lists
    // it as REQUIRED.
    const wallet = await installStubWallet(context);
    const seen = {};
    await stubServerHops(context, seen);

    await page.goto("/");
    const origin = new URL(page.url()).origin;
    await startEntryTrip(page);

    // WAIT FOR THE HOP, NOT FOR THE TRIP. A signing deeplink with no
    // redirect_link strands the trip by construction, so waiting on the landing
    // would report this defect as "waitForURL timed out" — a message that names
    // neither the hop nor the parameter, and sends the reader to the wrong end
    // of the flow. The wallet RECEIVES the malformed request either way, so the
    // hop is the observable to wait on.
    await expect
      .poll(() => (wallet.hop("signTransaction") ? "arrived" : null), { timeout: 25_000 })
      .toBe("arrived");

    const connect = wallet.hop("connect");
    const sign = wallet.hop("signTransaction");

    expect(connect.redirectLink, "the connect hop must name this app's callback").toBe(
      `${origin}${CALLBACK}`
    );
    expect(
      sign.redirectLink,
      "the SIGNING hop carried no redirect_link, so a wallet that signed had nowhere " +
        "to return the signed bytes — the user approves inside Phantom and never comes back"
    ).toBe(`${origin}${CALLBACK}`);

    // Connect is the protocol's one asymmetry: no shared secret exists yet, so
    // it carries no nonce and no payload. Both present on the signing hop.
    expect(connect.params.nonce).toBeUndefined();
    expect(connect.params.payload).toBeUndefined();
    expect(connect.params.app_url).toBe(origin);
    expect(sign.params.nonce).toBeTruthy();
    expect(sign.params.payload).toBeTruthy();

    // A real x25519 public key, 32 bytes decoded — not merely a plausible string.
    expect(decodeBase58(connect.params.dapp_encryption_public_key)).toHaveLength(32);
  });

  test("reaches the callback route with the intent still registered", async ({ page, context }) => {
    // THE NAMED TEST FOR THE FIRST DEFECT. Its predecessor
    // (contest_entry_callback_registration.spec.js) visits the callback page and
    // asks whether a NAME is registered. This one arrives there the way a wallet
    // sends a user — mid-trip, with a pending journal — and asserts the handler
    // RAN, which is the only thing that was ever at stake: walletOps.resume()
    // consumes the journal at take() BEFORE requireHandler, so an unregistered
    // intent loses the entry with nothing left to retry.
    const wallet = await installStubWallet(context);
    const seen = {};
    await stubServerHops(context, seen);

    await page.goto("/");
    await startEntryTrip(page);

    // The confirm POST only happens inside the registered handler's complete(),
    // on the callback document. Its arrival IS the proof the lookup resolved.
    await expect.poll(() => seen.confirm || null, { timeout: 25_000 }).not.toBeNull();
    expect(wallet.methods()).toContain("signTransaction");
  });

  test("is handed a driveable provider by the app's own resolver", async ({ page, context }) => {
    // THE NAMED TEST FOR THE SECOND DEFECT, asserted from the WALLET's side.
    // `detect()` used to answer null on a phone, so the board's redirect branch
    // was unreachable and every node test passed over it. Checking that the
    // returned object HAS a connect method is the check that missed it; the
    // check that cannot is whether a wallet ever received a connect request.
    const wallet = await installStubWallet(context);
    const seen = {};
    await stubServerHops(context, seen);

    await page.goto("/");
    await startEntryTrip(page);

    // `startEntryTrip` calls walletProvider.requireProvider() INSIDE the page, so
    // a resolver that answers null fails this test with the app's own
    // "open this page in your wallet app" sentence before a hop is ever built.
    // What is asserted here is the other half: that the provider it did hand
    // back could actually be DRIVEN as far as a real wallet request.
    await expect.poll(() => wallet.methods().length, { timeout: 15_000 }).toBeGreaterThan(0);
    expect(wallet.methods()[0]).toBe("connect");
    // …and that the request it built is one Phantom would accept. Reading a
    // page variable here would be a race — the document is on its way to the
    // wallet — so the observable is the wallet's own record.
    expect(wallet.violations).toEqual([]);
  });

  test("refuses to broadcast a co-signed entry itself", async ({ page, context }) => {
    // Phantom deprecated its signAndSendTransaction deeplink AND a contest entry
    // is co-signed — the server fills the second signer slot — so the wallet
    // must sign only. The stub records reaching that method as a violation, so
    // this asserts on the trip's shape rather than on a capability flag.
    const wallet = await installStubWallet(context);
    const seen = {};
    await stubServerHops(context, seen);

    await page.goto("/");
    await startEntryTrip(page);
    await page.waitForURL((url) => url.pathname === "/contests", { timeout: 25_000 });

    expect(wallet.methods()).not.toContain("signAndSendTransaction");
    // And the app, not the wallet, holds the signed bytes — the observable that
    // distinguishes the two branches at the server boundary.
    expect(seen.confirm.signed_tx).toBeTruthy();
  });

  test("surfaces a wallet rejection in the wallet's own words", async ({ page, context }) => {
    // VENDOR: an error redirect carries errorCode + errorMessage and NO data,
    // NO nonce — so a decrypt-first reader turns a clean user rejection into a
    // decryption exception, which is how balance advice ends up in front of
    // someone who attempted no transaction.
    const wallet = await installStubWallet(context, {
      answer: (hop) =>
        hop.method === "signTransaction"
          ? { errorCode: "4001", errorMessage: "User rejected the request." }
          : null,
    });
    const seen = {};
    await stubServerHops(context, seen);

    // A PERSON TAKES TIME TO SAY NO. A real rejection waits on a thumb inside the
    // wallet app; the stub answers at once. Holding the signing hop open for
    // longer than expect.poll's widest default interval (1s) makes this spec meet,
    // on EVERY runner, the window that reddened it on slow ones: a page read
    // issued while an outgoing hop is pending does not return. It waits for the
    // hop to commit, then throws "Execution context was destroyed", and
    // expect.poll retries a failing matcher but not a throwing generator. Measured
    // with the old body-text poll: 5 of 5 green without this delay, 5 of 5 red
    // with it, on the error CI printed.
    await context.route("https://phantom.app/ul/v1/signTransaction**", async (route) => {
      await new Promise((resolve) => setTimeout(resolve, 1_500));
      await route.fallback();
    });

    await page.goto("/");
    await startEntryTrip(page);

    // WAIT ON THE LEG THAT CARRIES THE ANSWER, NOT THE ROUTE IT SHARES. After the
    // board, the trip is four navigations (connect hop, callback, signing hop,
    // callback) and BOTH returns land on CALLBACK. The first is already on its way
    // back out to the wallet, so a pathname match can resolve on the wrong page:
    // measured 5 of 5 red when the connect return was made to reach its load
    // event before its outgoing hop. Today a pathname match passes only because
    // the connect return leaves before its own load, so the wait's load step
    // lands on the error leg by luck. Only the error leg carries errorCode, and
    // nothing after it navigates until showError's /signin fallback 30s later.
    // So once this resolves, with waitForURL's default "load", the document
    // showing the rejection is the one every read below reaches. waitForURL
    // reads no page state, so it cannot throw across the hops it waits through.
    await page.waitForURL(
      (url) => url.pathname === CALLBACK && url.searchParams.get("errorCode") === "4001",
      { timeout: 25_000 }
    );

    // THE SLOT, NOT THE BODY. Outside live production this app turns on the
    // callback's debug log (config/initializers/studio.rb), and that log prints
    // every URL parameter. The body therefore holds "User rejected the request."
    // as soon as the wallet redirects, whatever the page tells the user. Measured:
    // with the slot's copy changed, the old body read stayed green. #phantom-error
    // is where the callback's showError() writes the sentence the user reads, and
    // the slot e2e/wallet_sign_in.spec.js already reads. These two retry only
    // while showError runs on this document; the wait above leaves no navigation
    // for them to retry across.
    const errorSlot = page.locator("#phantom-error");
    await expect(errorSlot).toBeVisible();
    await expect(errorSlot).toHaveText("User rejected the request.");

    // The rejection came back on a well-formed request — the wallet only rejects
    // what it could read.
    expect(wallet.violations).toEqual([]);
    // And nothing was posted to the server for a transaction nobody signed.
    expect(seen.confirm).toBeUndefined();
  });
});

// ─────────────────────────────────────────────────────────────────────────────
// THE HARNESS'S OWN CONTROL.
//
// Every assertion above passes when the app is correct, which means none of them
// can tell you whether the contract table is READING. A stub whose checks are
// vacuous reports a clean bill on any request at all — and that is precisely the
// failure mode this whole file exists to retire, one layer up.
//
// So these two feed the stub requests that are wrong in the two ways that matter
// and assert it says so, by name. If either goes green-with-no-violation, the
// harness has stopped biting and every test above is worth nothing.
// ─────────────────────────────────────────────────────────────────────────────
test.describe("the harness itself", () => {
  test.use({ userAgent: IPHONE });

  test("names a signing deeplink that omits redirect_link", async ({ page, context }) => {
    const wallet = await installStubWallet(context);

    await page.goto(
      "https://phantom.app/ul/v1/signTransaction" +
        "?dapp_encryption_public_key=6dNVEJ4bJvLNAqCRcuHVaAqhrM7hkNJEbTLwjJzZSPBw" +
        "&nonce=11111111111111111111111111&payload=1111111111"
    );

    expect(wallet.violations.join("\n")).toContain('missing required query parameter "redirect_link"');
    // And the trip is STRANDED, not merely noted — a wallet with no return
    // address cannot answer, which is what a phone experiences.
    await expect(page.locator("[data-stub-wallet-dead-end]")).toBeVisible();
  });

  // THE OTHER HALF OF "IT SAYS SO": it must say so WITHOUT THROWING. A throw
  // inside a Playwright route handler leaves the request unfulfilled, so the trip
  // dies at waitForURL with a timeout — and a timeout names nothing, burying the
  // violation the stub already recorded. These two feed the stub the requests
  // that used to do exactly that.
  // CONNECT, NOT signTransaction, AND THE CHOICE IS THE WHOLE CONTROL. A signing
  // hop with no dapp key never reaches seal(): its payload cannot decrypt either,
  // so the "nothing to sign" guard below catches it first and this spec passes
  // with the secret guard DELETED — measured, not assumed. Connect is the branch
  // that seals immediately, so it is the one that isolates it.
  test("dead-ends a connect deeplink with no dapp_encryption_public_key", async ({ page, context }) => {
    const wallet = await installStubWallet(context);

    // REACHABLE, not contrived: wallet_transport's query builder drops an empty
    // value silently, which is the same mechanism that lost redirect_link.
    await page.goto(
      "https://phantom.app/ul/v1/connect" +
        "?app_url=https%3A%2F%2Fexample.test" +
        "&redirect_link=https%3A%2F%2Fexample.test%2Fcb"
    );

    expect(wallet.violations.join("\n")).toContain(
      'missing required query parameter "dapp_encryption_public_key"'
    );
    // THE POINT OF THIS CONTROL. Without the guard the handler throws at seal(),
    // the request is never fulfilled, and this locator never appears — the spec
    // fails on a timeout instead of on the sentence above.
    await expect(page.locator("[data-stub-wallet-dead-end]")).toBeVisible();
  });

  test("dead-ends a signing deeplink whose payload will not open", async ({ page, context }) => {
    const wallet = await installStubWallet(context);

    // A well-formed 32-byte dapp key, so a shared secret DOES derive — and a
    // payload that cannot be opened under it, so there is nothing to sign.
    await page.goto(
      "https://phantom.app/ul/v1/signTransaction" +
        "?dapp_encryption_public_key=6dNVEJ4bJvLNAqCRcuHVaAqhrM7hkNJEbTLwjJzZSPBw" +
        "&redirect_link=https%3A%2F%2Fexample.test%2Fcb" +
        "&nonce=11111111111111111111111111&payload=1111111111"
    );

    expect(wallet.violations.join("\n")).toContain("payload");
    // Without the guard this is decodeBase58(undefined) inside the handler.
    await expect(page.locator("[data-stub-wallet-dead-end]")).toBeVisible();
  });

  test("names a connect deeplink that carries a signing envelope", async ({ page, context }) => {
    const wallet = await installStubWallet(context);

    await page.goto(
      "https://phantom.app/ul/v1/connect" +
        "?app_url=https%3A%2F%2Fexample.test" +
        "&dapp_encryption_public_key=6dNVEJ4bJvLNAqCRcuHVaAqhrM7hkNJEbTLwjJzZSPBw" +
        "&redirect_link=https%3A%2F%2Fexample.test%2Fcb" +
        "&nonce=11111111111111111111111111&payload=1111111111"
    );

    const said = wallet.violations.join("\n");
    expect(said).toContain('carries "nonce"');
    expect(said).toContain('carries "payload"');
  });
});
