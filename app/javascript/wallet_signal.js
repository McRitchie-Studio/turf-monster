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
// WHAT THE PANEL AND THE CARD ACTUALLY GUARANTEE ABOUT EACH OTHER, written out
// because the shipped version of this file claimed more than that and was wrong.
//
//   GUARANTEED: they read the SAME list, so they never disagree about whether a
//   given switch was ASKED FOR. Declared here is exempt there, and undeclared
//   here raises the card there.
//
//   NOT GUARANTEED, and it never could be: that the two are in the same visual
//   state at the same instant. THEY RUN ON DIFFERENT CLOCKS. The card is raised
//   by a switch EVENT and then latches until the operator resolves it; this
//   panel is a LIVE reading that re-derives whenever any fact under it moves,
//   including facts that move with no wallet event at all. The header note above
//   ("what remains true on the page after that card closes") is that difference,
//   stated as a feature.
//
// THE COST OF FORGETTING THAT, MEASURED — the defect this file shipped with on
// 2026-09-17 and the reason rememberDeclaration() exists below. cosign.js clears
// the declared list in its `finally`, which runs the moment collect() returns,
// while Phantom is still parked on the signer it just used. Nothing about the
// wallet moved, so the card correctly stayed down — and this panel, reading the
// list live, went from expected/info to changed/DANGER and told the operator
// "No ceremony on this page asked for this wallet" seconds after one had. A
// false alarm on a treasury surface is how an operator learns to ignore the
// alarm, so the derivation now remembers a declaration for exactly as long as
// the wallet it named has not moved.
//
// Derivation is a pure function so it can be executed in node against the real
// module; the Alpine store below is a thin reactive wrapper around it.

// The eight states, in the order derive() decides them.
export const WALLET_SIGNAL_STATES = [
  "web2",         // signed in another way, on a page where the browser wallet signs nothing
  "guest",        // nobody is signed in. A first-class state, not an error.
  "unknown",      // the browser cannot be read yet. NEVER rendered as "no wallet".
  "none",         // no wallet provider in this browser at all
  "disconnected", // a provider is present and holds no account for this site
  "live",         // the connected wallet IS this account's wallet
  "expected",     // a different wallet, and this page DECLARED it (a cosign ceremony)
  "changed"       // a different wallet that nobody declared. The warning.
];

// The words, in TWO SETS, chosen by whether the session authenticated with a
// wallet. Here rather than in the partial so the copy is executable under node
// and a mutation to it goes red, and so the navbar chip and the ceremony panel
// can never drift into saying two different things about one fact.
//
// WHY TWO SETS. A session that signed in BY WALLET signature is accountable to
// that wallet: "Wallet connected" means the browser and the server agree about
// who you are. A session that signed in by magic link or Google never made that
// claim, so the same words would assert an identity the server has not
// authenticated. The facts are the same; only the sentence changes.
export const WALLET_SIGNAL_LABELS = {
  // The wallet IS the session's identity.
  wallet: {
    web2: "Managed wallet",
    guest: "Not signed in",
    unknown: "Checking wallet",
    none: "No wallet in this browser",
    disconnected: "Wallet not connected",
    live: "Wallet connected",
    expected: "Expected signer",
    changed: "Different wallet connected"
  },
  // The session signed in another way. On a page where the browser wallet is
  // what SIGNS, it still has to be named — it is just not an identity claim.
  other: {
    web2: "Managed wallet",
    guest: "Not signed in",
    unknown: "Checking wallet",
    none: "No wallet in this browser",
    disconnected: "Wallet not connected",
    live: "This account's wallet",
    expected: "Declared for this ceremony",
    changed: "Not declared for this ceremony"
  }
};

// Which label set a session gets. Exported so the store, the tests and any
// future consumer agree on the question rather than each asking it their way.
export function walletSignalLabel(state, walletAuthenticated) {
  const set = walletAuthenticated ? WALLET_SIGNAL_LABELS.wallet : WALLET_SIGNAL_LABELS.other;
  return set[state];
}

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

// Did this session prove ownership of a wallet? Only a live-signature login
// sets it, so a magic-link or Google admin is false here even when their
// account has a wallet linked from an earlier session.
export function walletAuthenticated(input) {
  const facts = input || {};
  return facts.sessionMode === "web3" && !!(facts.sessionAddress || "");
}

// THE DERIVATION. Pure: every input is passed in, nothing is read from the DOM.
//
//   status          "unknown" | "none" | "disconnected" | "connected"  (the gem)
//   observed        the connected address, or null
//   sessionAddress  the wallet on this account, or ""
//   sessionMode     "web3" | "web2" | "guest"  (SessionContext#mode)
//   declared        addresses an in-flight flow declared it will walk through
//   ceremony        true where the BROWSER wallet is what signs (a cosign page)
//   rememberedDeclaration
//                   one address this page declared, whose list has since been
//                   cleared while that exact wallet stayed connected. Advanced
//                   by rememberDeclaration() below and passed in, never guessed
//                   here, so the derivation stays pure.
//
// SESSION MODE NARROWS THE PAGE, NOT THE VOCABULARY — and the first cut of this
// file had that backwards, which is what sent it back.
//
// It returned `web2` for any session that did not authenticate by wallet
// signature, before ever reading the browser. That is right on an ordinary
// page: a managed session's browser wallet signs nothing there, so a wallet it
// happens to hold is not news. It is WRONG on a cosign ceremony page, and the
// population is ordinary and reachable: `require_admin` is `logged_in? &&
// admin?` with no session-mode requirement and `cosign.js` has no session-mode
// gate, so an admin who signed in by magic link reaches all three treasury
// surfaces and can co-sign there. Measured: that admin read `web2` / "Managed
// wallet" / muted whether Phantom sat on a wallet the ceremony had DECLARED or
// on a stranger's — the same words, the same grey dot, for the two cases this
// panel exists to tell apart, with the stranger's address printed under
// "Connected" directly above their own under "Session wallet". Silence would
// have been safer than that, because that reads as "checked, and content".
//
// So the rule is: a session that signed in BY WALLET is accountable to that
// wallet everywhere; a session that did not is accountable to it exactly where
// the browser wallet is what SIGNS. `ceremony` is that place, set by the page
// rather than guessed here. The states are then identical for both, and only
// the words change (WALLET_SIGNAL_LABELS above).
export function deriveWalletSignal(input) {
  const facts = input || {};
  const status = facts.status || "unknown";
  const observed = facts.observed || null;
  const sessionAddress = facts.sessionAddress || "";
  const declared = facts.declared || [];

  if (!walletAuthenticated(facts) && !facts.ceremony) {
    return sessionAddress ? "web2" : "guest";
  }

  if (status === "unknown") return "unknown";
  if (status === "none") return "none";
  if (status === "disconnected" || !observed) return "disconnected";

  // THE ACCOUNT'S OWN WALLET IS ASKED FIRST, and it stays first because
  // _notifySwitch asks it first too: that function returns before it ever
  // consults the declared list when the address equals the session's. Reordering
  // here would let the panel and the card disagree about one switch, which is
  // the one thing this component must never do.
  if (sessionAddress && observed === sessionAddress) return "live";

  // THE DECLARED / UNDECLARED SPLIT. Address-scoped, exactly as _notifySwitch
  // scopes the card it raises, so the signal and the card can never disagree
  // about which switch was asked for.
  for (let i = 0; i < declared.length; i++) {
    if (declared[i] === observed) return "expected";
  }

  // THE DECLARATION THAT OUTLIVED ITS LIST. The ceremony is over and the list is
  // empty, but Phantom has never left the signer the ceremony asked for — so
  // nothing happened that the card would have raised, and nothing happened that
  // this panel should raise either. `expected` rather than a ninth state: the
  // words are already past tense ("Declared for this ceremony"), the fact they
  // assert is still true, and a state the card has no counterpart for is a state
  // the two can drift on. rememberDeclaration() below is what keeps this branch
  // honest — it forgets the moment the wallet moves.
  if (facts.rememberedDeclaration && facts.rememberedDeclaration === observed) return "expected";

  return "changed";
}

// THE MEMORY BEHIND THAT BRANCH, as a pure function of (what we remembered, what
// is true now), so the rule is executable under node rather than buried in a
// listener.
//
// WHY "UNMOVED" IS THE WHOLE RULE. Remembering every address a page ever
// declared would be simpler and WRONG: once the flow ends its suppression ends
// too, so an operator who wanders off the declared signer and comes BACK to it
// gets the non-dismissible card — and a panel reading `expected` there would be
// contradicting a card that is on screen. Remembering only the wallet that never
// moved cannot produce that case.
export function rememberDeclaration(previous, input) {
  const facts = input || {};
  const observed = facts.observed || null;
  const declared = facts.declared || [];
  const held = previous || "";

  // NO WALLET IN VIEW ENDS IT. A lock, a disconnect, or a switch Phantom reports
  // as null all come back through _handleAccountChanged and raise the card on
  // the way in, so the panel has to be free to warn again.
  if (!observed) return "";

  // A LIVE ASK DECIDES EVERYTHING. While a ceremony is running its list is the
  // only authority — including when a SECOND ceremony asks for someone else,
  // which is exactly when a stale memory would read as calm over a wallet the
  // operator has to switch away from.
  if (declared.length) {
    for (let i = 0; i < declared.length; i++) {
      if (declared[i] === observed) return observed;
    }
    return "";
  }

  // Nothing is being asked for. The declaration survives only while the wallet
  // it named is still the one connected.
  return held === observed ? held : "";
}

// The full snapshot a view binds to.
export function walletSignalSnapshot(input) {
  const facts = input || {};
  const state = deriveWalletSignal(facts);
  const proved = walletAuthenticated(facts);
  const observed = facts.observed || null;
  const declared = facts.declared || [];
  const onLiveList = !!observed && declared.indexOf(observed) !== -1;
  return {
    state: state,
    status: facts.status || "unknown",
    address: facts.observed || null,
    sessionAddress: facts.sessionAddress || "",
    // The session row has to say so when the session did NOT sign in with a
    // wallet, or "Session wallet: <address>" reads as an authenticated pair.
    walletAuthenticated: proved,
    label: walletSignalLabel(state, proved),
    tone: WALLET_SIGNAL_TONES[state],
    short: shortAddress(facts.observed || ""),
    quiet: WALLET_SIGNAL_QUIET.indexOf(state) !== -1 && !facts.observed,
    // THE SAME LIST, WITHOUT THE ADDRESS CLAUSE — the panel's fallback lock.
    // `quiet` above is the CHIP's question ("is there anything worth painting"),
    // and a connected address is always worth painting, so it answers false for
    // precisely the case the panel needed covered: the ceremony flag failing to
    // read while a wallet IS connected, which renders a confident grey dot over
    // two different addresses. The panel therefore gates on the STATE alone.
    // Costs nothing on a real ceremony page: with ceremony=true the derivation
    // cannot return web2 or guest, so no quiet-listed state is reachable there.
    quietState: WALLET_SIGNAL_QUIET.indexOf(state) !== -1,
    // `expected` held by memory rather than by a live list: the ceremony that
    // asked for this wallet has finished and Phantom has not moved. The panel
    // says so in its own sentence instead of leaving the mid-ceremony one up.
    declarationEnded: state === "expected" && !onLiveList
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

// THE PROVIDER THIS APP WATCHES: the wallet the SESSION named, else the injected
// one.
//
// ONE OBJECT, TWO READERS. solana_stores' `_preferredProvider` resolves
// `registry.get(name) || registry.detect()` and watches whatever that returns.
// This function resolves the SAME named half, so whenever the session names a
// brand the registry can serve, the signal and the watcher hold the identical
// object and cannot end up describing two different wallets. Until 2026-09-19
// they genuinely could: the branch here tested `entry.detect()` on what `get()`
// returns, `detect` is a method on the REGISTRY and not on any provider, so the
// typeof test was always false and every call fell through to the injected
// wallet. Recorded as REVIEW NOTE 6 by Carl on
// /tasks/ceremony-page-lacks-wallet-signal.
//
// WHAT IT BUYS A READER, which is the whole reason it is worth binding. A
// Solflare- or Backpack-brand admin registers through Wallet Standard and injects
// nothing at `window.solana`. Measured on /admin/pending_transactions with the
// dead branch in place: gem status `none`, panel state `none`, "No wallet in this
// browser" — over a wallet whose adapter the registry was holding the whole time.
// That is the most expensive wrong answer the header of this file names, and it
// was being given to a real population.
//
// IT STILL CANNOT MIS-SIGN, and that is unchanged by the binding. cosign.js reads
// bare `window.solana` and hard-requires isPhantom, so a non-Phantom browser makes
// the co-sign REFUSE ("Wallet Required") rather than sign with a wallet this panel
// never described. Nothing here can route a signature anywhere.
//
// WHAT THE BINDING DOES CHANGE FOR THAT ADMIN, said plainly rather than left for
// someone to find: the panel now names their Solflare wallet, and the co-sign
// button still refuses it, so they read "This account's wallet" above a button
// that answers "Wallet Required". Before, the two agreed — by both being wrong
// about whether a wallet existed. That is the better trade and not a close call.
// The chip renders on EVERY page, not only the three cosign surfaces, so softening
// one button's refusal by telling every page there is no wallet is exactly the
// conflation this file's header forbids: "no wallet" and "a wallet this ceremony
// cannot use" are different facts, and cosign's own refusal already states the
// second one at the moment it applies. Teaching cosign.js the registry is the
// separate fix; it is not this one, and it does not belong in a signal.
//
// detect() IS DELIBERATELY LEFT OUT, so this takes the named half ONLY. It
// answers a different question — "pick something for a call site that cannot ask
// the user" — and both of its fallbacks are wrong here. Measured 2026-09-19
// against the installed solana-studio 0.12.0 asset and this repo's e2e lanes:
//
//   ON A PHONE it returns SolanaStudio.redirectProvider.forWallet('phantom'),
//   which carries no `publicKey` and no `on` at all (it speaks
//   beginConnect/completeConnect). The gem reads the absent key as null and
//   settles `disconnected`, whose tone is WARNING — so every mobile page on a
//   web3 session would trade a muted "No wallet in this browser", the honest
//   answer where no extension can exist, for a standing amber alarm that never
//   clears.
//
//   IN THE E2E AND BOT LANES it returns KeypairProvider, which is deaf — below.
//
// A DEAF PROVIDER IS NEVER BOUND. A provider whose `on()` registers nothing
// cannot report a switch, so binding one produces the single failure this whole
// file exists to prevent: a page that reads CALM while the wallet moves
// underneath it. KeypairProvider is exactly that shape (`on: function() {}` in
// app/javascript/wallet_provider.js), and no reflection can tell it from a real
// channel, because a no-op is a function like any other. So the deaf providers
// are NAMED here — and the naming is ENFORCED rather than trusted:
// test/lib/wallet_signal_js_test.rb drives `on()` on every provider `get()` can
// return, against a fixture whose every downstream channel is a spy, and demands
// that a provider which registered with none of them appear on this list.
//
// THE NAME IS NOT TODAY'S ONLY DEFENCE, and it is written down because the other
// one is invisible from this file. `get('keypair')` is unreachable from this call
// site today: the brand arrives from Solana::CurrentWallet or
// User#web3_wallet_provider, both of which store only what
// Solana::WalletProvider.normalize accepts, and that registry holds phantom,
// solflare and backpack. Adding "keypair" to it — for a bot lane, say — is a
// one-line change in Ruby that would silently make this page deaf. The guard
// belongs where the consequence lands.
export const SIGNAL_DEAF_PROVIDERS = ["keypair"];

// Pure, so the rule is executable under node: the registry, the brand and the
// injected provider all come in, and nothing is read from the DOM.
//
// A BLANK BRAND FALLS THROUGH, and that is the common case rather than an edge.
// `get("")` returns null anyway, but naming the guard states the population: a
// guest, a magic-link session on an account with no remembered brand, and every
// keypair sign-in (normalize rejects "keypair", so the column and the session key
// both stay empty) all arrive here with "" and read the injected wallet exactly
// as they did before.
export function hostProviderFor(registry, brand, injected) {
  try {
    if (registry && typeof registry.get === "function" && brand) {
      const named = registry.get(brand);
      const deaf = SIGNAL_DEAF_PROVIDERS.indexOf(String((named && named.name) || "").toLowerCase()) !== -1;
      if (named && typeof named.on === "function" && !deaf) return named;
    }
  } catch (e) { /* a registry that throws is one this page cannot use */ }
  return injected || null;
}

// Called on EVERY reconcile by design: window.walletProvider is an importmap
// MODULE and does not exist while the head is parsing, so a resolver that
// captured it once would capture null and never recover.
function hostProvider() {
  const injected = (window.phantom && window.phantom.solana) || window.solana || null;
  return hostProviderFor(window.walletProvider, sessionWalletBrand(), injected);
}

// IS THE BROWSER WALLET WHAT SIGNS ON THIS PAGE?
//
// Declared by the PAGE, not guessed here: shared/_wallet_signal stamps
// data-wallet-signal-ceremony on its panel, and the panel is rendered only by
// the three cosign surfaces. So the fact travels with the markup that means it,
// and a fourth ceremony page gets the behaviour by rendering the panel — the
// same "count the blocks, not the call sites" rule docs/AUTH.md already asks of
// this ceremony.
//
// Read live rather than captured: a Turbo visit swaps the body, and the answer
// has to describe the page on screen.
function ceremonyPage() {
  try {
    return !!document.querySelector("[data-wallet-signal-ceremony]");
  } catch (e) {
    return false;
  }
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

// THE PAGE'S MEMORY OF A DECLARATION — one variable, one writer, and the writer
// is called by both fact builders so neither can advance it alone.
let heldDeclaration = "";
let heldDeclarationPath = "";

function currentPath() {
  try {
    return (window.location && window.location.pathname) || "";
  } catch (e) {
    return "";
  }
}

// SCOPED TO THE PATH THAT DECLARED IT, and both halves of that are load-bearing.
//
//   IT SURVIVES A TURBO VISIT TO THE SAME PATH, because that is the one the
//   operator makes: cosign.js's success card closes with a link to
//   window.location.pathname, this module survives the visit, and solana_stores'
//   `watching` guard means its init does NOT re-run and cannot re-raise the card.
//   A memory cleared on turbo:load would hand the false alarm straight back the
//   moment the receipt is dismissed.
//
//   IT DIES ON THE WAY ANYWHERE ELSE, because "this page asked for this wallet"
//   is then a claim about a page the reader has left. A fresh page is also where
//   warning is cheap and right: the operator is parked on a vault signer with no
//   ceremony running.
//
// Idempotent by construction — one application reaches its own fixpoint — which
// is what makes it safe to call from an Alpine getter that re-evaluates freely.
function trackDeclaration(observed, declared) {
  const path = currentPath();
  if (path !== heldDeclarationPath) {
    heldDeclaration = "";
    heldDeclarationPath = path;
  }
  heldDeclaration = rememberDeclaration(heldDeclaration, { observed: observed, declared: declared });
  return heldDeclaration;
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
  const listeners = [];

  function facts() {
    const snap = source.current();
    const declared = declaredAddresses();
    return {
      status: snap.status,
      observed: snap.address,
      sessionAddress: sessionAddress(),
      sessionMode: sessionMode(),
      declared: declared,
      rememberedDeclaration: trackDeclaration(snap.address, declared),
      ceremony: ceremonyPage()
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

  // NO refreshSession() ON A SWITCH, AND THE REASON IS MEASURED.
  //
  // This file used to call it on every change of the connected address, under a
  // paragraph claiming a switch left the balance pill, the tiles, the seeds bar
  // and the token badge showing another wallet's values. That paragraph was
  // wrong, and a wrong reason is worse than no call, because the next author
  // reasons from it.
  //
  // AccountsController#session_refresh takes NO parameters and reads the browser
  // nowhere: it hydrates from `current_user&.solana_connected?` through
  // `fetch_navbar_hydrate(current_user)`, so every number it returns is keyed to
  // the SERVER's idea of the account. A browser wallet switch cannot stale any
  // of them, and the call repainted identical values while spending several
  // blocking Solana RPC reads each time — about three per three-signer ceremony,
  // on the page least able to afford a stall.
  //
  // What a switch DOES change is which wallet will sign, and that is what this
  // signal renders. If a future change makes some wallet-derived value actually
  // follow the browser, refresh it THEN, and say which value.
  source.subscribe(function () {
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
      get ceremony() { return ceremonyPage(); },
      get facts() {
        const declared = this.declared;
        return {
          status: this.status,
          observed: this.address,
          sessionAddress: this.sessionAddress,
          sessionMode: sessionMode(),
          declared: declared,
          // Advancing the memory from a GETTER is deliberate: it writes a module
          // variable and no store field, so it takes part in no reactive cycle,
          // and it is idempotent — so however many times Alpine re-evaluates
          // this, the answer is the same one publish() would have recorded.
          rememberedDeclaration: trackDeclaration(this.address, declared),
          ceremony: this.ceremony
        };
      },
      get state() { return deriveWalletSignal(this.facts); },
      // Whether the session PROVED this wallet, which decides the words and
      // whether the session row has to disclaim itself.
      get walletAuthenticated() { return walletAuthenticated(this.facts); },
      get label() { return walletSignalLabel(this.state, this.walletAuthenticated); },
      get tone() { return WALLET_SIGNAL_TONES[this.state]; },
      get short() { return shortAddress(this.address || ""); },
      get sessionShort() { return shortAddress(this.sessionAddress || ""); },
      // Nothing worth painting: signed out or managed, with no wallet in view.
      get quiet() {
        return WALLET_SIGNAL_QUIET.indexOf(this.state) !== -1 && !this.address;
      },
      // The panel's lock, on the STATE alone — see walletSignalSnapshot.
      get quietState() {
        return WALLET_SIGNAL_QUIET.indexOf(this.state) !== -1;
      },
      // Whether `expected` is being held by the memory rather than by a live
      // declared list, i.e. the ceremony has finished with this wallet.
      get declarationEnded() {
        const facts = this.facts;
        const declared = facts.declared || [];
        return this.state === "expected" &&
          !(facts.observed && declared.indexOf(facts.observed) !== -1);
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
