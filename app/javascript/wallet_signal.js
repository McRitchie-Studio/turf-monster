// THE WALLET SIGNAL — one answer to "which wallet is live", on every page.
//
// WHAT IT IS. A page-level, pre-auth-safe reading of the browser wallet, bound
// to the wallet the Rails session authenticated with. It renders through
// shared/_wallet_signal (navbar chip + page panel) and resolves on EVERY page,
// signed in or not.
//
// THE THREE LAYERS, and why none of them is duplicated here:
//
//   1. studio-engine (0.76.0+) owns SESSIONS. window.StudioSession compares the
//      identities a page was rendered for against the identities the browser
//      observes now, and fires session:changed / session:mismatch. It is web2 by
//      rule and knows nothing about wallets. docs/SESSION_DRIFT.md in that gem.
//   2. solana-studio (0.12.0+) owns the WALLET AS AN IDENTITY.
//      SolanaStudio.walletIdentity.register() plugs the connected address into
//      the engine as an identity source, reading the wallet LIVE on every probe
//      and re-reading on focus / visibilitychange / pageshow. Four statuses, and
//      the reason there are four rather than two is below.
//   3. THIS FILE owns the PRODUCT decision: what those facts mean to a reader of
//      Turf Monster, which wallet the page should name, and when a switch is a
//      warning. That is host work by construction and stays here.
//
// "NOT YET KNOWN" AND "NO WALLET" ARE DIFFERENT STATES. The single most
// expensive mistake available here is telling someone who has a wallet that they
// have none, during the ~3s the provider is still being discovered. The gem
// reports `unknown` for exactly that window and this file keeps it as its own
// state rather than folding it into `none`. The same distinction was fought over
// twice on /admin/authorities for the same reason.
//
// IT DOES NOT OPEN THE SWITCH CARD. app/javascript/solana_stores.js owns the
// non-dismissible `wallet-changed` modal and still does. This file paints the
// page-level signal that remains true after that card closes, and the signal the
// three cosign surfaces have never had at all.
//
// WHY THERE IS NO StudioSession.expectChange("wallet") HOLD, and this is the
// load-bearing decision of the whole change:
//
//   The engine's holds are per SOURCE, not per ADDRESS — solana-studio's README
//   says so in as many words. A hold taken for a cosign ceremony would mark
//   EVERY switch expected for as long as it is held, including a switch to a
//   wallet nobody declared. That is the one failure this signal exists to
//   prevent, and it fails SILENT.
//
//   turf's suppression is already address-scoped: $store.wallet.expectedSwitch-
//   Addresses lists the exact wallets the flow declared, and _notifySwitch
//   exempts only those. So the address check stays the single authority, this
//   file reads the same list, and no blanket hold is taken. The consequence is
//   that the engine still reports a declared ceremony switch as a mismatch — a
//   NOISY failure, which is the safe direction — and turf's own reading of the
//   same event is the one the reader sees.
//
// Derivation is a pure function so it can be executed in node against the real
// module; the Alpine store below is a thin reactive wrapper around it.

// The eight states, in the order derive() decides them.
export const WALLET_SIGNAL_STATES = [
  "web2",         // signed in with a managed/custodial wallet; the browser's is not this session's signer
  "guest",        // nobody is signed in. A first-class state, not an error.
  "unknown",      // web3 session, the browser cannot be read yet. NEVER rendered as "no wallet".
  "none",         // web3 session, no wallet provider in this browser at all
  "disconnected", // web3 session, a provider is present and holds no account for this site
  "live",         // the connected wallet IS the wallet this session signed in with
  "expected",     // a different wallet, and this page DECLARED it (a cosign ceremony)
  "changed"       // a different wallet that nobody declared. The warning.
];

// The words. Here rather than in the partial so the copy is executable under
// node and a mutation to it goes red, and so the navbar chip and the ceremony
// panel can never drift into saying two different things about one fact.
export const WALLET_SIGNAL_LABELS = {
  web2: "Managed wallet",
  guest: "Not signed in",
  unknown: "Checking wallet",
  none: "No wallet in this browser",
  disconnected: "Wallet not connected",
  live: "Wallet connected",
  expected: "Expected signer",
  changed: "Different wallet connected"
};

// Tone drives colour only. `info` is deliberately NOT `danger`: a declared
// ceremony switch is the flow working, and painting it red is how an operator
// learns to ignore the red.
export const WALLET_SIGNAL_TONES = {
  web2: "muted",
  guest: "muted",
  unknown: "muted",
  none: "muted",
  disconnected: "warning",
  live: "success",
  expected: "info",
  changed: "danger"
};

// Whether the signal has anything worth painting. A signed-out visitor with no
// wallet extension has nothing to say — but the state still RESOLVES to `guest`
// and is still readable from the store and from data-wallet-signal-state. The
// context exists pre-auth; only the chip is quiet.
export const WALLET_SIGNAL_QUIET = ["guest", "web2"];

// 4 + ellipsis + 4, matching cosign.js so one address never renders two ways.
export function shortAddress(key) {
  if (!key) return "";
  return key.length > 12 ? key.slice(0, 4) + "…" + key.slice(-4) : key;
}

// THE DERIVATION. Pure: every input is passed in, nothing is read from the DOM.
//
//   status          "unknown" | "none" | "disconnected" | "connected"  (the gem)
//   observed        the connected address, or null
//   sessionAddress  the wallet this Rails session authenticated with, or ""
//   sessionMode     "web3" | "web2" | "guest"  (SessionContext#mode)
//   declared        addresses an in-flight flow declared it will walk through
//
// Order is the contract. The session facts are known at render time and decide
// first; only a real wallet session reaches the browser-readability questions.
export function deriveWalletSignal(input) {
  const facts = input || {};
  const status = facts.status || "unknown";
  const observed = facts.observed || null;
  const sessionAddress = facts.sessionAddress || "";
  const declared = facts.declared || [];

  // Mirrors $store.wallet.state's own first line, so the two vocabularies agree
  // about who is signed in: a session is a wallet session only when the server
  // says web3 AND it actually bound an address.
  const isWeb3 = facts.sessionMode === "web3" && !!sessionAddress;
  if (!isWeb3) return sessionAddress ? "web2" : "guest";

  if (status === "unknown") return "unknown";
  if (status === "none") return "none";
  if (status === "disconnected" || !observed) return "disconnected";

  if (observed === sessionAddress) return "live";

  // THE DECLARED / UNDECLARED SPLIT. Address-scoped, exactly as _notifySwitch
  // scopes the card it raises, so the signal and the card can never disagree
  // about which switch was asked for.
  for (let i = 0; i < declared.length; i++) {
    if (declared[i] === observed) return "expected";
  }
  return "changed";
}

// The full snapshot a view binds to.
export function walletSignalSnapshot(input) {
  const facts = input || {};
  const state = deriveWalletSignal(facts);
  return {
    state: state,
    status: facts.status || "unknown",
    address: facts.observed || null,
    sessionAddress: facts.sessionAddress || "",
    label: WALLET_SIGNAL_LABELS[state],
    tone: WALLET_SIGNAL_TONES[state],
    short: shortAddress(facts.observed || ""),
    quiet: WALLET_SIGNAL_QUIET.indexOf(state) !== -1 && !facts.observed
  };
}

// ---------------------------------------------------------------------------
// The runtime half. Everything below reads the page; nothing above it does.
// ---------------------------------------------------------------------------

// SessionContext#mode off the server-rendered JSON, read directly rather than
// through Alpine.store('session') so it is correct regardless of which store
// registered first during alpine:init — the same reasoning solana_stores.js
// records for _isWeb3Session.
function sessionMode() {
  try {
    const el = document.getElementById("session-context");
    if (el) return JSON.parse(el.textContent).mode || "guest";
  } catch (e) { /* fall through */ }
  return "guest";
}

function sessionAddress() {
  return (document.body && document.body.dataset.walletAddress) || "";
}

function sessionWalletBrand() {
  try {
    const el = document.getElementById("session-context");
    if (el) {
      const brand = JSON.parse(el.textContent).walletBrand;
      if (brand) return brand;
    }
  } catch (e) { /* fall through */ }
  return (document.body && document.body.dataset.walletProvider) || "";
}

// The provider this app would watch. Prefers turf's own registry (the same one
// solana_stores.js resolves through, so the signal and the watcher can never
// end up bound to two different wallets), and falls back to the injected
// provider the gem would have picked by itself.
//
// Called on EVERY reconcile by design: window.walletProvider is an importmap
// MODULE and does not exist while the head is parsing, so a resolver that
// captured it once would capture null and never recover.
function hostProvider() {
  try {
    const registry = window.walletProvider;
    if (registry && typeof registry.get === "function") {
      const entry = registry.get(sessionWalletBrand());
      const found = entry && typeof entry.detect === "function" ? entry.detect() : null;
      if (found) return found;
    }
  } catch (e) { /* fall through to the injected provider */ }
  return (window.phantom && window.phantom.solana) || window.solana || null;
}

function declaredAddresses() {
  try {
    const store = window.Alpine && window.Alpine.store && window.Alpine.store("wallet");
    // Read off an Alpine store, so this is a PROXY of the array. Comparing its
    // string members is safe; comparing the array itself would not be.
    return (store && store.expectedSwitchAddresses) || [];
  } catch (e) {
    return [];
  }
}

function install() {
  if (window.tmWalletSignal) return window.tmWalletSignal;

  const identity = window.SolanaStudio && window.SolanaStudio.walletIdentity;
  if (!identity) {
    // The gem asset is not on this page, and on one layout that is CORRECT:
    // layouts/landing renders no navbar, no wallet chrome and none of the
    // solana-studio includes, so there is nothing here for the signal to paint.
    // It stays quiet rather than logging on every funnel page.
    //
    // The case that WOULD be a defect — the asset missing from the layout that
    // does render the navbar — is caught before production by a view test
    // (test/views/wallet_signal_component_test.rb) rather than by a console
    // line nobody reads.
    return null;
  }

  // A SILENT CONNECT IS NOT FREE — it can pop Phantom's unlock prompt — so it is
  // asked for ONLY on a live-signature session, the same gate solana_stores.js
  // puts on its own probe. A guest or a managed-wallet session reads the wallet
  // passively and never prompts.
  const web3 = sessionMode() === "web3" && !!sessionAddress();

  const registered = identity.register({
    name: "wallet",
    getProvider: hostProvider,
    trustedConnect: web3,
    // turf's registry announces a late-arriving wallet on this event; the gem
    // re-resolves the provider when it fires.
    rescanOn: ["wallet-provider:registered"]
  });

  const source = registered.source;
  // The last address the wallet was actually READ to hold. `undefined` means it
  // has never been read; `null` means it was read and holds nobody. Those are
  // different, and conflating them is what made the first version of this file
  // swallow a switch — see refreshOnSwitch below.
  let lastSettled;
  const listeners = [];

  function facts() {
    const snap = source.current();
    return {
      status: snap.status,
      observed: snap.address,
      sessionAddress: sessionAddress(),
      sessionMode: sessionMode(),
      declared: declaredAddresses()
    };
  }

  function current() {
    return walletSignalSnapshot(facts());
  }

  function publish() {
    const snapshot = current();
    try {
      const store = window.Alpine && window.Alpine.store && window.Alpine.store("walletSignal");
      if (store) {
        store.status = snapshot.status;
        store.address = snapshot.address;
      }
    } catch (e) { /* the next report republishes */ }
    listeners.slice().forEach(function (fn) {
      try { fn(snapshot); } catch (e) { console.warn("[wallet-signal] subscriber failed:", e); }
    });
    return snapshot;
  }

  // THE CALL ON A SWITCH — the applicational half that was missing.
  //
  // refreshSession() already runs on every page load through hydrateNavbar, so
  // the state a page OPENS with is correct. What had no trigger was a switch
  // made while the page stayed open: the balance pill, the tiles, the seeds bar
  // and the token badge all went on showing values pulled for a wallet the
  // browser was no longer holding.
  //
  // It is deliberately fired for ANY change of the observed address, declared or
  // not. A ceremony switch changes what the page should show just as much as an
  // accidental one does; what differs between them is the WARNING, not the data.
  //
  // NEVER on the page's own first reading of the wallet: hydrateNavbar has
  // already fired one, and firing again here would double every visit's
  // session_refresh.
  //
  // THE SENTINEL IS "HAS THE WALLET BEEN READ", NOT "HAVE WE HAD A REPORT", and
  // the difference is a swallowed switch. A subscriber only hears about a
  // CHANGE, so when the provider is already resolved at install time — a warm
  // extension, a Turbo visit, a bfcache restore — the store is seeded from
  // source.current() and no report follows. A counter keyed on reports then
  // spends its free pass on the user's FIRST REAL SWITCH instead of on the page
  // load, and the balances stay stale through exactly the event this exists to
  // catch. It was written that way, and the node tier caught it.
  //
  // `unknown` is not a reading. Passing through it on the way to an answer must
  // not look like the wallet moving.
  function refreshOnSwitch(snapshot) {
    if (snapshot.status === "unknown") return;
    if (lastSettled === undefined) { lastSettled = snapshot.address; return; }
    if (snapshot.address === lastSettled) return;
    lastSettled = snapshot.address;
    try {
      if (typeof window.refreshSession === "function") window.refreshSession();
    } catch (e) {
      console.warn("[wallet-signal] session refresh failed:", e);
    }
  }

  // Seed from whatever the wallet already says, so the sentinel is armed
  // whichever way round the provider and this module resolve.
  refreshOnSwitch(source.current());

  source.subscribe(function (snapshot) {
    refreshOnSwitch(snapshot);
    publish();
  });

  // A Turbo visit re-renders the body (new data-wallet-address, new
  // #session-context) while this module and the gem's source both survive it.
  // Re-publish so the signal describes the page on screen rather than the one it
  // was installed on.
  document.addEventListener("turbo:load", publish);

  function installStore() {
    const Alpine = window.Alpine;
    if (!Alpine || typeof Alpine.store !== "function") return;
    if (Alpine.store("walletSignal")) return;

    const seed = source.current();
    Alpine.store("walletSignal", {
      // Written by publish(); everything else is derived, so there is exactly
      // one place a wrong answer could come from.
      status: seed.status,
      address: seed.address,

      // Getters, not fields: Alpine re-evaluates them when the stores they read
      // change, which is how a cosign flow calling expectSwitchesTo() repaints
      // the panel without this file knowing the flow exists.
      get sessionAddress() { return sessionAddress(); },
      get declared() { return declaredAddresses(); },
      get state() {
        return deriveWalletSignal({
          status: this.status,
          observed: this.address,
          sessionAddress: this.sessionAddress,
          sessionMode: sessionMode(),
          declared: this.declared
        });
      },
      get label() { return WALLET_SIGNAL_LABELS[this.state]; },
      get tone() { return WALLET_SIGNAL_TONES[this.state]; },
      get short() { return shortAddress(this.address || ""); },
      get sessionShort() { return shortAddress(this.sessionAddress || ""); },
      // Nothing worth painting: signed out or managed, with no wallet in view.
      get quiet() {
        return WALLET_SIGNAL_QUIET.indexOf(this.state) !== -1 && !this.address;
      },
      is: function (state) { return this.state === state; }
    });
  }

  if (window.Alpine && window.Alpine.store) installStore();
  document.addEventListener("alpine:init", installStore);

  window.tmWalletSignal = {
    current: current,
    refresh: publish,
    source: source,
    registration: registered.registration,
    subscribe: function (fn) {
      listeners.push(fn);
      return function () {
        const at = listeners.indexOf(fn);
        if (at !== -1) listeners.splice(at, 1);
      };
    }
  };
  return window.tmWalletSignal;
}

// Executed for its side effect on a real page only, so the pure exports above
// can be imported under node without a DOM.
if (typeof window !== "undefined" && typeof document !== "undefined" && document.body !== undefined) {
  install();
}

export { install };
