const { test, expect } = require("@playwright/test");
const { loginAdmin, reseed } = require("./helpers");

// [e2e] WHICH PROVIDER THE WALLET SIGNAL BINDS, in a real browser.
//
// The companion is test/lib/wallet_signal_js_test.rb, which drives the same rule
// under node against the real solana-studio identity source. It cannot see this:
// the object the signal binds is chosen from `window.walletProvider`, an importmap
// MODULE that does not exist until the page has loaded it, and a Wallet Standard
// wallet arrives by a handshake no node harness performs. Both specs here assert
// values only a live page can produce — the bound provider's own name, read off
// `window.tmWalletSignal`, and the panel's painted state attribute.
//
// WHY THIS PAGE. /admin/pending_transactions is a cosign ceremony surface, so the
// signal renders its PANEL there and the derivation runs for an email-authenticated
// admin — the population Carl's REVIEW NOTE 6 was written about.
//
// ── THE FIRST SPEC: THE DEFECT ──────────────────────────────────────────────
//
// `hostProvider()` had a registry branch that could not fire — it tested
// `entry.detect()` on what `walletProvider.get(brand)` returns, and `detect` is a
// method on the REGISTRY rather than on any provider. So every call fell through
// to `(window.phantom && window.phantom.solana) || window.solana`, and a Solflare-
// or Backpack-brand admin, whose wallet registers through Wallet Standard and
// injects nothing at `window.solana`, was told they have no wallet at all.
//
// ── THE SECOND SPEC: THE FAILURE THE FIX MUST NOT BUY ───────────────────────
//
// A provider whose `on()` registers nothing cannot report a switch, so binding one
// leaves a page reading CALM while the wallet moves underneath it. That is the one
// thing this component exists to prevent, and it is strictly worse than the defect
// above: "no wallet" is visibly wrong and a reader distrusts it, while a green dot
// over a stale address is wrong and reassuring. `KeypairProvider.on` is exactly
// that shape, so `SIGNAL_DEAF_PROVIDERS` refuses it by name, and this spec
// measures the refusal the only way it can be measured — by moving the wallet and
// requiring the alarm.
//
// THE SESSION FACTS ARE SET IN THE BROWSER, the same way and for the same reason
// e2e/wallet_signal_ceremony.spec.js sets them: this admin signs in by email, so
// the server binds no wallet to the session and a browser wallet could never
// mismatch it. `data-wallet-provider` and `#session-context` ARE the server's own
// channel for those facts, so writing them drives the code under test through the
// interface it reads in production — and it touches no row, so no sibling spec
// inherits a rewritten wallet.

const SOLFLARE_WALLET = "So1F1areWa11etAddress1111111111111111111111";
const SESSION_WALLET = "SessionWa11etAddress111111111111111111111111";
const STRANGER_WALLET = "Stranger11111111111111111111111111111111111";

// Tell the page it is a web3 session on `brand`, then force the identity source
// to RE-RESOLVE its provider.
//
// THE RESCAN IS NOT OPTIONAL AND NOT A TEST-ONLY POKE. An accountChanged event
// folds into the binding the gem already holds; only a reconcile re-resolves which
// provider to watch. `wallet-provider:registered` is the registry's own
// late-wallet announcement and wallet_signal.js passes it as `rescanOn`, so this
// is the production path a provider change arrives on. Omitting it is how the
// first cut of this measurement reported a pass that meant nothing.
async function declareSession(page, { brand, address }) {
  await page.evaluate(
    ({ b, a }) => {
      document.body.dataset.walletAddress = a;
      document.body.dataset.walletProvider = b;
      const el = document.getElementById("session-context");
      const payload = JSON.parse(el.textContent);
      payload.mode = "web3";
      payload.walletBrand = b;
      el.textContent = JSON.stringify(payload);
      window.dispatchEvent(
        new CustomEvent("wallet-provider:registered", { detail: { name: b } })
      );
    },
    { b: brand, a: address }
  );
  await page.waitForTimeout(200);
}

const boundProvider = (page) =>
  page.evaluate(() => {
    const snap = window.tmWalletSignal.source.current();
    return { providerName: snap.providerName, status: snap.status, address: snap.address };
  });

test.beforeEach(async ({ request }) => await reseed(request));

test("the signal binds the wallet the session named, not whatever is injected @smoke", async ({ page }) => {
  // A Wallet Standard wallet and NOTHING at window.solana — Solflare's and
  // Backpack's actual shape. `accounts` is the wallet's own live view, which is
  // what the adapter's publicKey getter re-reads.
  await page.addInitScript((address) => {
    const changeListeners = [];
    let account = {
      address: address,
      publicKey: new Uint8Array(32),
      chains: ["solana:mainnet"],
      features: ["solana:signMessage"]
    };
    const wallet = {
      name: "Solflare",
      icon: "data:image/svg+xml;base64,",
      chains: ["solana:mainnet"],
      get accounts() { return account ? [account] : []; },
      features: {
        "standard:connect": {
          version: "1.0.0",
          connect: async () => ({ accounts: wallet.accounts })
        },
        "standard:disconnect": {
          version: "1.0.0",
          disconnect: async () => { account = null; }
        },
        "standard:events": {
          version: "1.0.0",
          on: (event, cb) => {
            if (event === "change") changeListeners.push(cb);
            return () => {};
          }
        },
        "solana:signMessage": {
          version: "1.0.0",
          signMessage: async () => [{ signature: new Uint8Array(64) }]
        }
      }
    };
    // The test's hand on the wallet: move the account it reports LIVE, then
    // announce it the way Wallet Standard does — an accounts array on `change`.
    window.__moveSolflare = (next) => {
      account = next
        ? { address: next, publicKey: new Uint8Array(32), chains: ["solana:mainnet"], features: [] }
        : null;
      changeListeners.forEach((cb) => cb({ accounts: wallet.accounts }));
    };
    // Both halves of the registration handshake, because which one fires depends
    // on whether the wallet or the app loaded first.
    window.addEventListener("wallet-standard:app-ready", (e) => {
      try { e.detail.register(wallet); } catch (err) { /* the other half covers it */ }
    });
    window.dispatchEvent(
      new CustomEvent("wallet-standard:register-wallet", { detail: (api) => api.register(wallet) })
    );
  }, SOLFLARE_WALLET);

  await loginAdmin(page);
  await page.goto("/admin/pending_transactions");

  const panel = page.locator("[data-wallet-signal-variant=panel]");
  await expect(panel).toHaveCount(1);
  await page.waitForFunction(() => window.tmWalletSignal && window.Alpine && window.Alpine.store("walletSignal"));

  // THE DEFECT, MEASURED FIRST so the pass below cannot be vacuous. With no brand
  // named, the signal reads the injected wallet — and there is none, because this
  // wallet only ever registered through Wallet Standard. The gem's discovery
  // window has to close before `none` is its settled answer.
  await expect(panel).toHaveAttribute("data-wallet-signal-state", "none", { timeout: 6000 });
  expect((await boundProvider(page)).providerName).toBeNull();

  // Now the session names the brand, exactly as a Solflare sign-in does.
  await declareSession(page, { brand: "solflare", address: SOLFLARE_WALLET });

  const bound = await boundProvider(page);
  expect(bound.providerName).toBe("Solflare");
  expect(bound.status).toBe("connected");
  // BOUND MEANS READ: the address has to come off the adapter. A fall-through to
  // the injected wallet leaves this null, which is the whole defect.
  expect(bound.address).toBe(SOLFLARE_WALLET);
  await expect(panel).toHaveAttribute("data-wallet-signal-state", "live");

  // AND THE BINDING CARRIES A LIVE CHANNEL. A switch the SOLFLARE wallet announces
  // — not the injected one, which does not exist here — moves the panel.
  await page.evaluate((next) => window.__moveSolflare(next), STRANGER_WALLET);
  await page.waitForTimeout(200);
  await expect(panel).toHaveAttribute("data-wallet-signal-state", "changed");
  await expect(page.locator("[data-wallet-signal-changed-note]")).toBeVisible();
  expect((await boundProvider(page)).address).toBe(STRANGER_WALLET);

  // The navbar chip is the app-wide half of the same fact.
  const chip = page.locator("[data-wallet-signal-variant=chip]").first();
  await expect(chip).toHaveAttribute("data-wallet-signal-state", "changed");
});

test("a provider that cannot report a switch is refused, so no wallet moves under a calm panel @smoke", async ({ page }) => {
  await page.addInitScript(() => {
    // A real injected provider: a publicKey that moves and an `on` that registers.
    const handlers = {};
    const injected = {
      isPhantom: true,
      name: "phantom",
      publicKey: null,
      on: (event, cb) => { (handlers[event] = handlers[event] || []).push(cb); },
      removeListener: (event, cb) => {
        handlers[event] = (handlers[event] || []).filter((fn) => fn !== cb);
      },
      connect: async () => ({ publicKey: injected.publicKey }),
      disconnect: async () => {}
    };
    window.__setWallet = (address) => {
      injected.publicKey = address ? { toBase58: () => address } : null;
      (handlers.accountChanged || []).forEach((cb) => cb(injected.publicKey));
    };
    window.solana = injected;
    window.phantom = { solana: injected };

    // KeypairProvider's shape, verbatim in the part that matters: `on()` registers
    // nothing, and the address is whatever connect() loaded — it cannot move and
    // it cannot announce. Frozen ON the session wallet, because that is the shape
    // of the DANGEROUS failure: a page bound to it reads a correct-looking green
    // dot for ever, whatever the browser's wallet actually does.
    const deaf = {
      name: "keypair",
      on: function () { /* no-op */ },
      connect: function () { return Promise.resolve({ publicKey: deaf.publicKey }); },
      get publicKey() { return { toBase58: () => window.__DEAF_ADDRESS }; }
    };
    window.__deafReports = () => deaf.publicKey.toBase58();

    // Stand in for the registry entry the session's brand resolves to. Wrapping
    // the accessor is how a test reaches a value an importmap module writes after
    // the head has parsed.
    let installed = null;
    Object.defineProperty(window, "walletProvider", {
      configurable: true,
      get() { return installed; },
      set(value) {
        installed = value;
        const realGet = value.get.bind(value);
        value.get = (name) => (String(name).toLowerCase() === "phantom" ? deaf : realGet(name));
      }
    });
  });

  await loginAdmin(page);
  await page.goto("/admin/pending_transactions");
  const panel = page.locator("[data-wallet-signal-variant=panel]");
  await page.waitForFunction(() => window.tmWalletSignal && window.Alpine && window.Alpine.store("walletSignal"));

  await page.evaluate((address) => { window.__DEAF_ADDRESS = address; }, SESSION_WALLET);

  // THE SESSION FACTS LAND WHILE THE WALLET IS STILL EMPTY, and the order is
  // load-bearing rather than tidy. `$store.walletSignal.state` is an Alpine getter
  // over `sessionAddress()`, which reads a body attribute — and a body attribute is
  // not reactive, so writing one repaints NOTHING. Only a store field the module
  // publishes (status / address) moves the panel. Setting the facts first and the
  // wallet second gives the address a real null -> SESSION transition, so the
  // attribute this spec asserts describes the facts under it. Written the other way
  // round, the panel reported a state three edits old and the spec read a stale
  // attribute as a verdict.
  await declareSession(page, { brand: "phantom", address: SESSION_WALLET });

  // THE REFUSAL. The registry hands back the deaf provider for this brand and the
  // signal must decline it, staying on the injected wallet — which is the ONLY
  // reason the alarm below can still fire.
  expect((await boundProvider(page)).providerName).toBe("phantom");

  await page.evaluate((address) => window.__setWallet(address), SESSION_WALLET);
  await expect(panel).toHaveAttribute("data-wallet-signal-state", "live");

  // THE MEASUREMENT. The wallet the browser actually holds moves to a stranger.
  await page.evaluate((address) => window.__setWallet(address), STRANGER_WALLET);
  await page.waitForTimeout(200);

  // The precondition, asserted rather than assumed: the deaf provider would have
  // gone on reporting the session wallet, so a page bound to it paints calm.
  expect(await page.evaluate(() => window.__deafReports())).toBe(SESSION_WALLET);

  // And the property. `live` here is the silent calm; it must be `changed`.
  await expect(panel).toHaveAttribute("data-wallet-signal-state", "changed");
  await expect(page.locator("[data-wallet-signal-changed-note]")).toBeVisible();
  expect((await boundProvider(page)).address).toBe(STRANGER_WALLET);
});
