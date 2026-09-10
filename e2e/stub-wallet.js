// THE STAND-IN WALLET — a wallet-shaped receiver, not a wallet-shaped mock.
//
// WHY THIS EXISTS AND WHY IT IS NOT "ONE MORE TEST". Three defects in the mobile
// wallet epic reached a real phone before anything red appeared:
//
//   1. the contest_entry intent was not registered on the page a wallet RETURNS
//      to, so an approved entry was lost with nothing left to retry;
//   2. `walletProvider.detect()` handed a phone `null`, so the redirect branch
//      in the board was unreachable dead code;
//   3. the SIGNING hop's deeplink carried no `redirect_link`, so a wallet that
//      signed had nowhere to send the answer.
//
// Every existing test in this area missed all three, and the reason is
// structural rather than careless: they CONSTRUCT the provider by hand, drive it
// with options they supply themselves, and never look at what a wallet would
// actually RECEIVE. solana-studio's own round-trip suite is the sharpest example
// — it calls `O.resume(params, { redirectLink: 'https://a.test/cb', ... })`, and
// the real callback page (studio-engine's solana_sessions/phantom_callback)
// passes only `{ navigate }`. The test manufactures the exact parameter
// production is missing, so defect 3 was invisible to a green suite.
//
// So this file stands WHERE PHANTOM STANDS. It intercepts the universal link,
// judges the request against the VENDOR'S documented parameter table, decrypts
// the payload with the dapp key THE URL CARRIES, and answers by redirecting to
// THE `redirect_link` THE URL CARRIES. That last clause is the whole design: the
// stub cannot reach the callback page by any route the wallet could not, so a
// malformed outgoing deeplink does not merely fail an assertion — it strands the
// trip exactly as it strands a user.
//
// ─────────────────────────────────────────────────────────────────────────────
// PROVENANCE OF EVERY EXPECTATION BELOW. This is the part that decides whether
// the harness is worth anything: a stub shaped from our own code can only
// certify our own assumptions, which is how the three defects passed. Each
// entry in CONTRACT carries `source` and `confidence`, and the rules are:
//
//   VENDOR   — read from Phantom's published docs at docs.phantom.com,
//              fetched 2026-09-09. These can falsify our code.
//   OURS     — derived from this codebase (the gem's profile table, a call
//              site). These CANNOT falsify our code and are marked so; they are
//              here for shape, never as the thing under test.
//
// Three protocol "facts" in circulation during this epic were wrong on first
// reading — Phantom's signAndSendTransaction deeplink is DEPRECATED, no vendor
// ships a documented signIn deeplink, and a co-signed contest entry must never
// be broadcast by the wallet — so nothing here is asserted without a citation.
// ─────────────────────────────────────────────────────────────────────────────
const nacl = require("tweetnacl");

// Base58, written HERE rather than imported from the code under test. The app's
// encoder is one of the things this harness judges; borrowing it would make a
// wrong encoder agree with itself. (solana-studio's own comment records the
// encoder bug that shipped past eleven passing tests for exactly this reason.)
const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";

function encodeBase58(bytes) {
  let zeros = 0;
  while (zeros < bytes.length && bytes[zeros] === 0) zeros++;
  const digits = [];
  for (let i = zeros; i < bytes.length; i++) {
    let carry = bytes[i];
    for (let j = 0; j < digits.length; j++) {
      carry += digits[j] << 8;
      digits[j] = carry % 58;
      carry = (carry / 58) | 0;
    }
    while (carry) { digits.push(carry % 58); carry = (carry / 58) | 0; }
  }
  let out = "1".repeat(zeros);
  for (let m = digits.length - 1; m >= 0; m--) out += B58[digits[m]];
  return out;
}

function decodeBase58(str) {
  const bytes = [];
  for (const ch of String(str)) {
    const idx = B58.indexOf(ch);
    if (idx < 0) throw new Error(`invalid base58 character ${JSON.stringify(ch)}`);
    let carry = idx;
    for (let j = 0; j < bytes.length; j++) {
      carry += bytes[j] * 58;
      bytes[j] = carry & 0xff;
      carry >>= 8;
    }
    while (carry) { bytes.push(carry & 0xff); carry >>= 8; }
  }
  for (let k = 0; k < str.length && str[k] === "1"; k++) bytes.push(0);
  return new Uint8Array(bytes.reverse());
}

// --- The vendor's parameter contract -----------------------------------------
//
// One entry per deeplink method this app can emit. `required` is what the wallet
// REFUSES to work without; `forbidden` is what its presence proves the caller
// misunderstood the protocol.
const CONTRACT = {
  connect: {
    path: "/ul/v1/connect",
    source: "VENDOR — docs.phantom.com/phantom-deeplinks/provider-methods/connect, fetched 2026-09-09",
    confidence: "high",
    required: ["app_url", "dapp_encryption_public_key", "redirect_link"],
    optional: ["cluster"],
    // THE ONE ASYMMETRY IN THE PROTOCOL, and the reason connect cannot reuse the
    // signing envelope: the shared secret does not exist yet, so there is
    // nothing to encrypt and nothing to encrypt it with. Phantom's connect page
    // lists no nonce and no payload; either one here means a caller reached for
    // the signing builder.
    forbidden: ["nonce", "payload"],
  },
  signTransaction: {
    path: "/ul/v1/signTransaction",
    source: "VENDOR — docs.phantom.com/phantom-deeplinks/provider-methods/signtransaction, fetched 2026-09-09",
    confidence: "high",
    // Phantom's own words: dapp_encryption_public_key, nonce, redirect_link and
    // payload are ALL required. redirect_link is the one this repo was missing.
    required: ["dapp_encryption_public_key", "nonce", "redirect_link", "payload"],
    optional: [],
    forbidden: ["app_url"],
    // The decrypted payload's keys, per the same page ("encrypted JSON
    // containing transaction and session token").
    payloadRequired: ["transaction", "session"],
  },
  signAndSendTransaction: {
    path: "/ul/v1/signAndSendTransaction",
    // DEPRECATED BY PHANTOM ("Use signAllTransactions or signTransaction
    // instead"), and a contest entry is CO-SIGNED — the server fills the second
    // signer slot — so a wallet must never broadcast it. Reaching this method at
    // all is a violation for this app, which is why it has no success answer
    // below: the stub records it and stops.
    source: "VENDOR — docs.phantom.com deprecation notice + this app's co-signed entry (see shared/_contest_entry_intent)",
    confidence: "high",
    required: ["dapp_encryption_public_key", "nonce", "redirect_link", "payload"],
    optional: [],
    forbidden: [],
    payloadRequired: ["transaction", "session"],
  },
  signMessage: {
    path: "/ul/v1/signMessage",
    source: "VENDOR — docs.phantom.com/phantom-deeplinks/provider-methods/signmessage, fetched 2026-09-09",
    confidence: "high",
    required: ["dapp_encryption_public_key", "nonce", "redirect_link", "payload"],
    optional: [],
    forbidden: [],
    // `display` is documented OPTIONAL ("utf8" or "hex", defaulting to utf8), so
    // it is not required here. No flow in this app emits signMessage today — the
    // entry is a transaction and sign-in still runs the legacy phantom_dl_* path
    // — so this row is the contract waiting for the flow, not a live assertion.
    payloadRequired: ["message", "session"],
  },
};

// The response key Phantom returns its encryption public key under. VENDOR —
// connect page, "phantom_encryption_public_key". Solflare and Backpack fork this
// name; only Phantom is driven here.
const CONNECT_PUBLIC_KEY_PARAM = "phantom_encryption_public_key";

// x25519 + TweetNaCl. Phantom's encryption page documents the Diffie-Hellman key
// exchange over x25519 keypairs and points implementers at TweetNaCl.js; it does
// NOT spell out the box construction or the nonce length. So: the KEY EXCHANGE
// is vendor-documented (high confidence) and the 24-byte nonce + box.after
// envelope come from tweetnacl's own API, which the docs nominate (medium — an
// unstated detail inferred from the library the vendor names).
const NONCE_BYTES = 24;

// The stand-in for the user's ed25519 signature: 64 bytes, the size and position
// a real one occupies at the head of a serialised Solana transaction. A fixed
// filler so a spec can assert the SERVER received the wallet's bytes followed by
// the transaction the server itself prepared — a round trip, not a coincidence.
const SIGNATURE_STUB = new Uint8Array(64).fill(0x5a);

function methodFor(url) {
  for (const [name, spec] of Object.entries(CONTRACT)) {
    if (url.pathname === spec.path) return name;
  }
  return null;
}

/**
 * Install the stand-in wallet on a Playwright BrowserContext.
 *
 * @param {import('@playwright/test').BrowserContext} context
 * @param {object} [opts]
 * @param {string} [opts.userPublicKey]  the address the wallet connects as
 * @param {string} [opts.session]        the session token connect issues
 * @param {(hop) => object|null} [opts.answer]
 *        Per-hop override. Return `{ errorCode, errorMessage }` to answer as a
 *        rejecting wallet, `{ data: {...} }` to change the sealed body, or null
 *        for the default. Called AFTER the contract check, so a rejection still
 *        proves the request was well formed.
 * @returns {Promise<object>} the wallet handle
 */
async function installStubWallet(context, opts = {}) {
  const walletKeypair = nacl.box.keyPair();
  const userPublicKey = opts.userPublicKey || "5tzFkiKscXHK5ZXCGbXZxdw7gTjjD1mBwuoFbhUvuAi9";
  const sessionToken = opts.session || "stub-session-" + encodeBase58(nacl.randomBytes(8));

  const wallet = {
    // Every request the wallet received, in order, fully parsed.
    hops: [],
    // Contract breaches, in order. A spec asserts this is empty; the MESSAGES
    // are the deliverable, so each names the method, the parameter and the
    // vendor page it comes from.
    violations: [],
    // The signed bytes this wallet handed back, so a spec can prove the SAME
    // bytes reached the server rather than merely that something did.
    signedTransactions: [],
    publicKey: userPublicKey,
    signatureStub: SIGNATURE_STUB,
    session: sessionToken,
    encryptionPublicKey: encodeBase58(walletKeypair.publicKey),
    methods() { return this.hops.map((h) => h.method); },
    lastHop() { return this.hops[this.hops.length - 1] || null; },
    hop(method) { return this.hops.find((h) => h.method === method) || null; },
  };

  function violate(method, message) {
    wallet.violations.push(`${method}: ${message}`);
  }

  function sharedSecretFor(dappPublicKeyB58) {
    return nacl.box.before(decodeBase58(dappPublicKeyB58), walletKeypair.secretKey);
  }

  function seal(body, secret) {
    const nonce = nacl.randomBytes(NONCE_BYTES);
    const bytes = new TextEncoder().encode(JSON.stringify(body));
    return {
      nonce: encodeBase58(nonce),
      data: encodeBase58(nacl.box.after(bytes, nonce, secret)),
    };
  }

  // The stub answers the way a wallet answers: by sending the browser to the
  // redirect_link it was handed. Served as a document that replaces itself, not
  // a 302, because that is the shape of a real universal-link handoff — the OS
  // opens the wallet app and the app opens the callback.
  function redirectTo(route, target, params) {
    const url = new URL(target);
    for (const [k, v] of Object.entries(params)) url.searchParams.set(k, v);
    return route.fulfill({
      status: 200,
      contentType: "text/html",
      body: `<!doctype html><title>stub wallet</title><script>location.replace(${JSON.stringify(url.toString())})</script>`,
    });
  }

  // A wallet that cannot answer. This is what a missing redirect_link REALLY
  // costs: the trip stops here, with the user inside the wallet app, exactly as
  // it stops on a phone.
  function deadEnd(route, why) {
    return route.fulfill({
      status: 200,
      contentType: "text/html",
      body: `<!doctype html><title>stub wallet — dead end</title>` +
            `<h1 data-stub-wallet-dead-end="1">${why.replace(/[<&]/g, "")}</h1>`,
    });
  }

  await context.route("https://phantom.app/**", async (route) => {
    const url = new URL(route.request().url());
    const method = methodFor(url);

    if (!method) {
      // /ul/browse/<encoded target> is the third-tier handoff and carries no
      // protocol. Anything else on this host is a request this app should not
      // have built.
      if (url.pathname.startsWith("/ul/browse/")) {
        wallet.hops.push({ method: "browse", url: url.toString() });
        return deadEnd(route, "browse handoff (not driven by this harness)");
      }
      violate("unknown", `no vendor contract for path ${url.pathname}`);
      return deadEnd(route, `unknown deeplink ${url.pathname}`);
    }

    const spec = CONTRACT[method];
    const q = url.searchParams;
    const hop = {
      method,
      url: url.toString(),
      params: Object.fromEntries(q.entries()),
      payload: null,
      redirectLink: q.get("redirect_link"),
    };
    wallet.hops.push(hop);

    // --- 1. the parameter table, straight from the vendor page ---------------
    for (const name of spec.required) {
      if (!q.get(name)) {
        violate(method, `missing required query parameter "${name}" (${spec.source})`);
      }
    }
    for (const name of spec.forbidden) {
      if (q.get(name) !== null) {
        violate(method, `carries "${name}", which this method does not take (${spec.source})`);
      }
    }
    for (const name of q.keys()) {
      if (!spec.required.includes(name) && !(spec.optional || []).includes(name)) {
        // Not a violation on its own — an undocumented extra is a smell, not a
        // refusal — but recorded so a spec can pin the exact set if it wants to.
        hop.extraParams = (hop.extraParams || []).concat(name);
      }
    }

    // --- 2. the dapp key must be a real x25519 public key ---------------------
    const dappKey = q.get("dapp_encryption_public_key");
    let secret = null;
    if (dappKey) {
      let decoded = null;
      try { decoded = decodeBase58(dappKey); } catch (e) {
        violate(method, `dapp_encryption_public_key is not base58: ${e.message}`);
      }
      if (decoded && decoded.length !== 32) {
        violate(method, `dapp_encryption_public_key decodes to ${decoded.length} bytes, not the 32 an x25519 key has`);
      }
      if (decoded && decoded.length === 32) secret = sharedSecretFor(dappKey);
      hop.dappPublicKey = dappKey;
    }

    // --- 3. the payload must actually decrypt, and say what the method needs --
    if (spec.payloadRequired && q.get("payload") && q.get("nonce") && secret) {
      // WRAPPED, because tweetnacl THROWS on a wrong-sized nonce rather than
      // answering false — and a throw inside a Playwright route handler leaves
      // the request unfulfilled, so the browser reports a detached frame and the
      // real finding ("the nonce is not 24 bytes") never reaches the report.
      let opened = null;
      try {
        opened = nacl.box.open.after(
          decodeBase58(q.get("payload")), decodeBase58(q.get("nonce")), secret
        );
      } catch (e) {
        violate(method, `payload could not be opened: ${e.message}`);
      }
      if (!opened) {
        violate(method, "payload does not decrypt under the shared secret derived from the key this URL carries");
      } else {
        try {
          hop.payload = JSON.parse(new TextDecoder().decode(opened));
        } catch (e) {
          violate(method, `payload decrypted but is not JSON: ${e.message}`);
        }
        for (const key of spec.payloadRequired) {
          if (hop.payload && !hop.payload[key]) {
            violate(method, `decrypted payload has no "${key}" (${spec.source})`);
          }
        }
        if (hop.payload && hop.payload.session && hop.payload.session !== sessionToken) {
          violate(method, `payload carries session ${JSON.stringify(hop.payload.session)}, not the one this wallet issued at connect`);
        }
      }
    }

    // --- 4. answer, the only way a wallet can: via redirect_link -------------
    if (!hop.redirectLink) {
      return deadEnd(route,
        `${method} carried no redirect_link — this wallet has nowhere to send the answer`);
    }

    const override = opts.answer ? opts.answer(hop) : null;
    if (override && override.errorCode) {
      // VENDOR — every method's error redirect is errorCode + errorMessage, with
      // no data and no nonce. 4001 is the user rejection.
      return redirectTo(route, hop.redirectLink, {
        errorCode: String(override.errorCode),
        errorMessage: override.errorMessage || "User rejected the request.",
      });
    }

    if (method === "connect") {
      const body = (override && override.data) || { public_key: userPublicKey, session: sessionToken };
      const sealed = seal(body, secret);
      return redirectTo(route, hop.redirectLink, {
        [CONNECT_PUBLIC_KEY_PARAM]: wallet.encryptionPublicKey,
        nonce: sealed.nonce,
        data: sealed.data,
      });
    }

    if (method === "signTransaction") {
      // A REAL SIGNATURE IS NOT SIMULATED, and it does not need to be. What the
      // app must prove is that the BYTES the wallet returns reach the server
      // intact, so the answer is the wire bytes it was sent with a 64-byte
      // sentinel prepended — the shape and position a real ed25519 signature
      // occupies in a serialised Solana transaction.
      //
      // WHY BYTES AND NOT A STRING TAG, learned the hard way here: an earlier
      // cut answered `"SIGNED" + payload.transaction`, and "I" is not in the
      // base58 alphabet (0/O/I/l are excluded), so the handler's decode threw
      // "Invalid base58 character" on the callback page. A wallet answers bytes;
      // a stub that answers anything else is testing a different protocol.
      let signed;
      if (override && override.data && override.data.transaction) {
        signed = override.data.transaction;
      } else {
        const sent = decodeBase58(hop.payload ? hop.payload.transaction : "");
        const out = new Uint8Array(SIGNATURE_STUB.length + sent.length);
        out.set(SIGNATURE_STUB, 0);
        out.set(sent, SIGNATURE_STUB.length);
        signed = encodeBase58(out);
      }
      wallet.signedTransactions.push(signed);
      const sealed = seal({ transaction: signed }, secret);
      return redirectTo(route, hop.redirectLink, { nonce: sealed.nonce, data: sealed.data });
    }

    if (method === "signAndSendTransaction") {
      violate(method,
        "reached signAndSendTransaction — Phantom deprecated this deeplink AND a co-signed " +
        "contest entry can never be wallet-broadcast (the server fills the second signer slot)");
      return deadEnd(route, "signAndSendTransaction is not a path this app may take");
    }

    if (method === "signMessage") {
      const sealed = seal({ signature: "STUBSIG" }, secret);
      return redirectTo(route, hop.redirectLink, { nonce: sealed.nonce, data: sealed.data });
    }

    return deadEnd(route, `unhandled method ${method}`);
  });

  return wallet;
}

module.exports = {
  installStubWallet,
  SIGNATURE_STUB,
  CONTRACT,
  CONNECT_PUBLIC_KEY_PARAM,
  encodeBase58,
  decodeBase58,
};
