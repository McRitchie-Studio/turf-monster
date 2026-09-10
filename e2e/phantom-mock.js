/**
 * Phantom wallet mock for Playwright E2E tests.
 *
 * Injects a fake `window.phantom.solana` provider that uses real Ed25519
 * signing via tweetnacl CDN — so the server's `verify_solana_signature!`
 * works unchanged.
 *
 * Usage:
 *   const { setupPhantomMock, MOCK_PUBKEY_B58 } = require('./phantom-mock');
 *   await setupPhantomMock(page);              // seed byte 1 = alex
 *   await setupPhantomMock(page, { seedByte: 2 }); // different wallet
 *   await setupPhantomMock(page, { walletStandard: true }); // late WS adapter
 *   await setupPhantomMock(page, { signIn: false }); // a wallet WITHOUT SIWS
 */

// ── SIGN IN WITH SOLANA, AND WHY THIS MOCK NOW ADVERTISES IT ─────────────────
//
// THE DEFECT THIS FIXES IS IN THE MOCK ITSELF. Until 2026-09-07 nothing here
// exposed `signIn` on either interface, so `supportsSignIn()` was false for every
// spec that used this file and all of them drove the connect + signMessage
// FALLBACK — a route real Phantom has not taken since it shipped SIWS. The suite
// was green against a provider shaped like our code instead of like the wallet,
// which is why no test could see that the whole malfunction class was reporting
// our own sentence as the wallet's (/tasks/raw-message-is-ours). A stub shaped
// from the handler certifies the handler.
//
// SHAPED FROM THE SPEC, NOT FROM app/. Sources, both fetched 2026-09-07:
//
//   * Wallet Standard feature name, version and method — anza-xyz/wallet-standard,
//     packages/core/features/src/signIn.ts:
//         export const SolanaSignIn = 'solana:signIn';
//         readonly [SolanaSignIn]: { readonly version; readonly signIn }
//     with `SolanaSignInMethod` taking `readonly SolanaSignInInput[] inputs` and
//     resolving `Promise<readonly SolanaSignInOutput[]>` — an ARRAY, which is why
//     the Wallet Standard half below returns one.
//
//   * The output fields — phantom/sign-in-with-solana (the SIWS spec Phantom
//     published and implements), SolanaSignInOutput:
//         account [WalletAccount]: Account that was signed in.
//         signedMessage [Uint8Array]: Message bytes that were signed. The wallet
//           is responsible for constructing this message using the signInInput.
//         signature [Uint8Array]: Message signature produced.
//         signatureType ["ed25519"]: Optional type of the message signature.
//     THE WALLET COMPOSES THE MESSAGE. That sentence is the contract our own
//     layout depends on — solanaConnectAndVerify verifies against the bytes the
//     wallet returned and never a rebuilt string — so this mock composes its own
//     message rather than echoing one back.
//
// BOTH INTERFACES, because this app has two and a mock pinned to one certifies
// half: the legacy injected provider (window.phantom.solana) and the Wallet
// Standard adapter. Their output shapes DIFFER and wallet_provider.js's
// normalizeSignInOutput carries a branch for each — `o.account.address` for the
// Wallet Standard shape, `o.address` for the injected one, where it may be a
// string or a PublicKey. The Wallet Standard half below returns the first shape
// and the legacy half the PublicKey form of the second, so between them both
// branches of that normalizer run.
//
// AND signIn CONNECTS. It is a drop-in replacement for connect + signMessage, so
// both halves below adopt the account they just signed with — isConnected and
// publicKey on the legacy provider, standardAccount on the Wallet Standard one.
// A signIn that signed without connecting would leave every later call in a spec
// rejecting with "Wallet not connected".


// Pre-computed from deterministic seed (last byte = 1)
const MOCK_PUBKEY_B58 = "6ASf5EcmmEHTgDJ4X4ZT5vT6iHVJBXPg5AN5YoTCpGWt";

/**
 * Inject Phantom mock into the page via addInitScript.
 * Runs before any page scripts — Alpine's walletAvailable check passes immediately.
 */
async function setupPhantomMock(page, {
  seedByte = 1,
  walletStandard = false,
  connectError = null,
  // Real Phantom advertises solana:signIn, so this mock does too by default.
  // Pass `signIn: false` for the genuinely SIWS-less wallet — that is a real
  // provider shape, and it is the ONLY way to reach the connect + signMessage
  // fallback now, which is exactly how it should read in a spec.
  signIn = true,
  // How signIn fails, when it does. Defaults to `connectError`, because the
  // failure this file exists to model — an installed extension holding no
  // keypair — rejects BOTH calls with Phantom's generic 'Unexpected error'
  // (production, 2026-09-06). Pass it explicitly for the other real case: a
  // signIn that fails while connect + signMessage still works.
  signInError = undefined,
  // How signMessage fails, when it does. Distinct from `connectError` ON
  // PURPOSE: it is the ONLY way to reach the fallback's `connected` guard, which
  // requires connect() to have ANSWERED with a publicKey and signMessage to
  // refuse afterwards. An extension holding no keypair cannot model that — it
  // fails connect() first — so a spec for that guard cannot be written with
  // `connectError` no matter how it is shaped.
  signMessageError = null
} = {}) {
  await page.addInitScript(({ initialSeedByte, useWalletStandard, rejectConnectWith, advertiseSignIn, rejectSignInWith, rejectSignMessageWith }) => {
    let currentSeedByte = Number(localStorage.getItem("phantomMockSeedByte")) || initialSeedByte;

    // --- Base58 encoder (Bitcoin alphabet) ---
    const B58 = "123456789ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz";
    function encodeBase58(bytes) {
      let n = BigInt(0);
      for (const b of bytes) n = n * 256n + BigInt(b);
      let r = "";
      while (n > 0n) {
        r = B58[Number(n % 58n)] + r;
        n = n / 58n;
      }
      for (const b of bytes) {
        if (b !== 0) break;
        r = "1" + r;
      }
      return r || "1";
    }

    // --- Lazy tweetnacl loader ---
    let _keypair = null;
    let _naclLoaded = false;

    function loadTweetnacl() {
      if (_naclLoaded) return Promise.resolve();
      if (typeof nacl !== "undefined" && nacl.sign) {
        _naclLoaded = true;
        return Promise.resolve();
      }
      return new Promise((resolve, reject) => {
        const s = document.createElement("script");
        s.src = "https://cdn.jsdelivr.net/npm/tweetnacl@1.0.3/nacl-fast.min.js";
        s.onload = () => {
          _naclLoaded = true;
          resolve();
        };
        s.onerror = reject;
        (document.head || document.documentElement).appendChild(s);
      });
    }

    async function getKeypair() {
      if (_keypair) return _keypair;
      await loadTweetnacl();
      const seed = new Uint8Array(32);
      seed[31] = currentSeedByte;
      _keypair = nacl.sign.keyPair.fromSeed(seed);
      return _keypair;
    }

    // --- Public key helper ---
    function makePublicKey(bytes) {
      return {
        toBytes: () => bytes,
        toBase58: () => encodeBase58(bytes),
        toString: () => encodeBase58(bytes),
      };
    }

    // The message a WALLET composes for a SIWS input — "The wallet is
    // responsible for constructing this message using the signInInput"
    // (phantom/sign-in-with-solana, SolanaSignInOutput.signedMessage). Shaped so
    // it satisfies the three things solanaConnectAndVerify checks the returned
    // bytes against: it must OPEN with `domain + " "`, carry `Nonce: <nonce>`,
    // and in link mode carry the User-ID the layout inlines into `statement`.
    // Byte-identical to buildSiwsMessage in app/javascript/wallet_provider.js,
    // which the keypair test provider uses for the same job.
    function siwsMessage(input, address) {
      return (
        (input.domain || "") + " wants you to sign in with your Solana account:\n" +
        address + "\n\n" +
        (input.statement || "") + "\n\n" +
        "Nonce: " + (input.nonce || "")
      );
    }

    // A rejection carrying only the own-properties the real wallet sets. Shared
    // by connect() and signIn() so an extension that holds no keypair fails both
    // the same way, which is what production did on 2026-09-06.
    function walletRejection(spec) {
      const err = new Error(spec.message);
      if (spec.code !== undefined && spec.code !== null) err.code = spec.code;
      return err;
    }

    // --- Phantom provider mock ---
    const listeners = {};
    const standardChangeListeners = [];
    let standardAccount = null;
    function emit(event, value) {
      (listeners[event] || []).forEach((callback) => callback(value));
    }

    function makeStandardAccount(bytes) {
      return {
        address: encodeBase58(bytes),
        publicKey: bytes,
        chains: ["solana:devnet", "solana:mainnet"],
        // A WalletAccount lists the features it supports, and Phantom's lists
        // solana:signIn alongside solana:signMessage. Kept in step with what the
        // wallet advertises so the account cannot claim less than its wallet.
        features: advertiseSignIn
          ? ["solana:signMessage", "solana:signIn"]
          : ["solana:signMessage"],
      };
    }

    const solana = {
      isPhantom: true,
      isConnected: false,
      publicKey: null,

      // A WALLET THAT WILL NOT CONNECT. Two real cases share this shape and
      // both are what e2e/wallet_failure_report.spec.js drives:
      //   * the user declines the prompt — Phantom rejects with
      //     `{ code: 4001, message: 'User rejected the request.' }`;
      //   * the extension is installed but holds no keypair, so it is sitting on
      //     its own create-or-import screen and rejects with a bare
      //     'Unexpected error' and NO code (production, 2026-09-06).
      //
      // SHAPED FROM PHANTOM, NOT FROM OUR HANDLER. The `code` is a separate own
      // property and is deliberately ABSENT unless a caller asks for it: the app
      // branches on `e.code === 4001` OR the message text, and a mock that always
      // set a code would certify the code branch while the text branch — the one
      // that actually catches Wallet Standard wallets — went unexercised.
      async connect() {
        if (rejectConnectWith) throw walletRejection(rejectConnectWith);
        const kp = await getKeypair();
        this.isConnected = true;
        this.publicKey = makePublicKey(kp.publicKey);
        return { publicKey: this.publicKey };
      },

      async disconnect() {
        this.isConnected = false;
        this.publicKey = null;
        standardAccount = null;
        // REAL PHANTOM ANNOUNCES A DISCONNECT. This mock used to mutate the two
        // fields above and emit NOTHING, so a spec asserting the app's reaction
        // to a disconnect passed whether or not the app had subscribed at all —
        // and the app had not: `grep -rn "'disconnect'" app/javascript/
        // app/views/` found zero listeners. A stub that is quieter than the real
        // thing certifies silence as success.
        if (useWalletStandard) {
          standardChangeListeners.forEach((callback) => callback({ accounts: [] }));
        } else {
          emit("disconnect", undefined);
        }
      },

      async signMessage(message) {
        if (rejectSignMessageWith) throw walletRejection(rejectSignMessageWith);
        const kp = await getKeypair();
        const signature = nacl.sign.detached(message, kp.secretKey);
        return { signature };
      },

      // SIGN IN WITH SOLANA, INJECTED-PROVIDER SHAPE. Defined only when the mock
      // advertises it (see the deleteIfNoSignIn line below): `supportsSignIn()`
      // on the legacy provider is literally `typeof p.signIn === 'function'`
      // (wallet_provider.js), so a wallet without SIWS is a wallet without this
      // property — not one that owns it and refuses.
      //
      // `address` is returned as a PublicKey OBJECT rather than a base58 string.
      // Both are legal on this interface — normalizeSignInOutput accepts either,
      // and says the injected shape is version-dependent — and the Wallet
      // Standard half below returns the string form via `account.address`, so
      // between them the mock runs both branches of that normalizer instead of
      // certifying one.
      async signIn(input) {
        if (rejectSignInWith) throw walletRejection(rejectSignInWith);
        const kp = await getKeypair();
        // signIn CONNECTS as well as signs — it replaces connect + signMessage,
        // so the site is connected afterwards exactly as if connect() had run.
        this.isConnected = true;
        this.publicKey = makePublicKey(kp.publicKey);
        const signedMessage = new TextEncoder().encode(
          siwsMessage(input || {}, this.publicKey.toBase58())
        );
        return {
          address: this.publicKey,
          signedMessage,
          signature: nacl.sign.detached(signedMessage, kp.secretKey),
          signatureType: "ed25519",
        };
      },

      async signTransaction(tx) {
        const kp = await getKeypair();
        // solanaWeb3 is loaded from the page's CDN
        const solKp = solanaWeb3.Keypair.fromSecretKey(kp.secretKey);
        tx.partialSign(solKp);
        return tx;
      },

      on(event, callback) {
        listeners[event] ||= [];
        listeners[event].push(callback);
      },

      off(event, callback) {
        listeners[event] = (listeners[event] || []).filter((item) => item !== callback);
      },

      async __switchAccount(nextSeedByte, { transientNull = false, emitEvent = true } = {}) {
        if (transientNull && emitEvent) {
          if (useWalletStandard) {
            standardChangeListeners.forEach((callback) => callback({ accounts: [] }));
          } else {
            emit("accountChanged", null);
          }
        }
        await new Promise((resolve) => setTimeout(resolve, 25));
        currentSeedByte = nextSeedByte;
        localStorage.setItem("phantomMockSeedByte", String(nextSeedByte));
        _keypair = null;
        const kp = await getKeypair();
        this.isConnected = true;
        this.publicKey = makePublicKey(kp.publicKey);
        standardAccount = makeStandardAccount(kp.publicKey);
        if (emitEvent) {
          if (useWalletStandard) {
            standardChangeListeners.forEach((callback) => callback({ accounts: [standardAccount] }));
          } else {
            emit("accountChanged", this.publicKey);
          }
        }
      },

      // Switching to an account that has NEVER approved this site is not an
      // account change — Phantom disconnects the site instead. The observable
      // sequence is `accountChanged` carrying null, then the connection torn
      // down, then a `disconnect`. Modelled separately from __switchAccount
      // because the app must answer them DIFFERENTLY: a concrete switch is a
      // re-auth handoff, this is a degrade.
      //
      // No `nextSeedByte` — the point is that no account becomes current.
      async __switchToUnapprovedAccount() {
        if (useWalletStandard) {
          standardChangeListeners.forEach((callback) => callback({ accounts: [] }));
        } else {
          emit("accountChanged", null);
        }
        await new Promise((resolve) => setTimeout(resolve, 25));
        this.isConnected = false;
        this.publicKey = null;
        standardAccount = null;
        _keypair = null;
        // NO `disconnect` EMIT HERE, deliberately. Phantom's contract for an
        // unapproved account is `accountChanged` WITH NO ARGUMENTS — the site is
        // disconnected, but the null IS the notification. Emitting both would
        // model Phantom wrongly AND hide a bug: with two events covering one
        // fact, a spec stays green when the null path is broken because the
        // disconnect path catches it. Measured — that is exactly what happened
        // here on 2026-08-26, and the swallowed-null mutation passed.
      },
    };

    // A WALLET WITHOUT SIWS IS A WALLET WITHOUT THE PROPERTY. Deleting it here
    // rather than never defining it keeps the two halves of this object written
    // once; `supportsSignIn()` reads `typeof p.signIn === 'function'`, so this is
    // the difference the app actually branches on.
    if (!advertiseSignIn) delete solana.signIn;

    window.phantom = { solana };

    // TEST-VISIBLE PRECONDITION. The Wallet Standard `disconnect` is delivered
    // by notifying standardChangeListeners — and a notification sent before the
    // app has subscribed is not queued, retried, or recoverable: it lands in an
    // empty array and is gone. A spec that disconnects must therefore be able to
    // ask whether anyone is listening yet.
    //
    // Do NOT "fix" that by having disconnect() also emit on the legacy provider.
    // The Wallet Standard translation being a silent no-op is the exact defect
    // PR #443 fixed, and it survived for months precisely because the legacy
    // channel masked it. A louder mock would put the mask back.
    window.__phantomMockWsChangeSubscribers = () => standardChangeListeners.length;

    if (useWalletStandard) {
      const wallet = {
        name: "Phantom",
        chains: ["solana:devnet", "solana:mainnet"],
        get accounts() { return standardAccount ? [standardAccount] : []; },
        features: {
          "standard:connect": {
            version: "1.0.0",
            connect: async () => {
              // A WALLET THAT WILL NOT CONNECT, ON THIS INTERFACE TOO. This half
              // ignored `connectError` until 2026-09-07, so a spec asking for an
              // extension that cannot answer got a Wallet Standard wallet that
              // always could — the same one-sided modelling that left
              // solana:signIn off both halves. Both interfaces reach the app's
              // failure paths, so both have to be able to fail.
              if (rejectConnectWith) throw walletRejection(rejectConnectWith);
              const kp = await getKeypair();
              standardAccount = makeStandardAccount(kp.publicKey);
              return { accounts: [standardAccount] };
            },
          },
          "standard:disconnect": {
            version: "1.0.0",
            disconnect: async () => { standardAccount = null; },
          },
          "standard:events": {
            version: "1.0.0",
            on: (event, callback) => {
              if (event === "change") standardChangeListeners.push(callback);
              return () => {
                const index = standardChangeListeners.indexOf(callback);
                if (index >= 0) standardChangeListeners.splice(index, 1);
              };
            },
          },
          "solana:signMessage": {
            version: "1.0.0",
            signMessage: async ({ message }) => {
              if (rejectSignMessageWith) throw walletRejection(rejectSignMessageWith);
              const kp = await getKeypair();
              return [{ signature: nacl.sign.detached(message, kp.secretKey) }];
            },
          },
        },
      };

      // SIGN IN WITH SOLANA, WALLET STANDARD SHAPE. Attached conditionally
      // because `supportsSignIn()` on the adapter is `!!wallet.features
      // ['solana:signIn']` (wallet_provider.js) — the absence of the KEY is what
      // a SIWS-less wallet looks like from the app's side.
      //
      // Verbatim to anza-xyz/wallet-standard packages/core/features/src/signIn.ts:
      // the feature name is 'solana:signIn', it carries { version, signIn }, and
      // SolanaSignInMethod takes `readonly SolanaSignInInput[] inputs` and
      // resolves `Promise<readonly SolanaSignInOutput[]>` — hence the rest
      // parameter and the ARRAY return. Our adapter passes a single input and
      // reads outputs[0], which is one legal caller of that signature; a mock
      // that resolved a bare object would let a caller that stopped unwrapping
      // the array pass anyway.
      if (advertiseSignIn) {
        wallet.features["solana:signIn"] = {
          version: "1.0.0",
          signIn: async (...inputs) => {
            if (rejectSignInWith) throw walletRejection(rejectSignInWith);
            const kp = await getKeypair();
            // signIn CONNECTS: the account it signed with becomes the wallet's
            // current account, exactly as standard:connect would have left it.
            standardAccount = makeStandardAccount(kp.publicKey);
            const signedMessage = new TextEncoder().encode(
              siwsMessage(inputs[0] || {}, standardAccount.address)
            );
            return [{
              account: standardAccount,
              signedMessage,
              signature: nacl.sign.detached(signedMessage, kp.secretKey),
              signatureType: "ed25519",
            }];
          },
        };
      }

      // Model Phantom's real lifecycle: its legacy injected provider exists
      // first, then Wallet Standard registers the adapter that the hub uses.
      //
      // THE DELAY IS A TEST INSTRUMENT, NOT A GUESS. It was 150ms, which on a
      // warm local machine is always shorter than the time a spec takes to
      // reach its first assertion — so the swap always won locally, and whether
      // a spec had waited for it was untestable here. On CI it did not always
      // win, and e2e/wallet_disconnect.spec.js failed there and only there,
      // three runs running, blocking every PR. A number large enough to LOSE
      // the race every time makes the ordering deterministic in both places:
      // a spec that must wait for the Wallet Standard adapter now fails
      // everywhere if it stops waiting, instead of failing on CI a week later.
      window.addEventListener("wallet-standard:app-ready", (event) => {
        setTimeout(() => event.detail.register(wallet), 1500);
      });
    }

    // --- Inject dummy CSRF meta tag ---
    // Test env has allow_forgery_protection=false so Rails skips csrf_meta_tags.
    // The wallet connect JS needs it (no optional chaining on .content).
    document.addEventListener("DOMContentLoaded", () => {
      if (!document.querySelector('meta[name="csrf-token"]')) {
        const meta = document.createElement("meta");
        meta.name = "csrf-token";
        meta.content = "test-csrf-token";
        document.head.appendChild(meta);
      }
    }, { once: true });
  }, {
    initialSeedByte: seedByte,
    useWalletStandard: walletStandard,
    rejectConnectWith: connectError,
    advertiseSignIn: signIn,
    // AN EMPTY EXTENSION FAILS BOTH CALLS. When a caller sets `connectError` and
    // says nothing about signIn, signIn fails the same way — that is the shape
    // of the wallet this file models, and letting signIn succeed there would
    // hand the app a working sign-in from a wallet that holds no keypair.
    rejectSignInWith: signInError === undefined ? connectError : signInError,
    rejectSignMessageWith: signMessageError,
  });
}

module.exports = { MOCK_PUBKEY_B58, setupPhantomMock };
