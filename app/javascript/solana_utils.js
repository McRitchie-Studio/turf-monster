// Shared Solana/crypto utilities — fetch helpers, balance refresh, confetti colors
// Base58 encode/decode lives in base58.js (canonical source, loaded before this module)

// Deduplication-safe fetch — prevents concurrent requests for the same key
const _lockedKeys = {};
export function lockedFetch(key, url, opts) {
  if (_lockedKeys[key]) return Promise.resolve(null);
  _lockedKeys[key] = true;
  return fetch(url, opts).finally(function() { delete _lockedKeys[key]; });
}

// Auth-aware fetch — wraps fetch() and surfaces server-side logouts.
// If the server returns 401 (cookie expired, CSRF mismatch, session cleared
// in another tab), the client's $store.session still thinks we're logged in.
// authedFetch flips $store.session to guest, closes any pending solanaModal,
// and opens the auth modal at the login step. Returns null on 401 so
// callers can short-circuit with `if (!resp) return;` instead of trying to
// parse a 401 body as a normal response.
//
// Debounced: a burst of parallel 401s only triggers one modal open.
var _sessionExpiredHandled = false;
var _rateLimitHandled = false;

export function solanaNetworkInfo() {
  var body = document.body || {};
  var cluster = (body.dataset && body.dataset.solanaCluster) || '';
  var env = (body.dataset && body.dataset.appEnvironment) || '';
  var label = cluster === 'mainnet-beta' ? 'Mainnet' : (cluster === 'devnet' ? 'Devnet' : 'Strange Network');
  var expected = env === 'production' ? 'mainnet-beta' : 'devnet';
  var envLabels = { qa: 'QA', production: 'Production', development: 'Development', test: 'Test' };
  return {
    cluster: cluster,
    environment: env,
    networkLabel: label,
    environmentLabel: envLabels[env] || (env ? (env.charAt(0).toUpperCase() + env.slice(1)) : 'Unknown'),
    expectedCluster: expected,
    mismatch: !cluster || cluster !== expected || (cluster !== 'mainnet-beta' && cluster !== 'devnet')
  };
}

export function confirmSolanaNetworkIntent(opts) {
  opts = opts || {};
  var info = solanaNetworkInfo();
  if (!info.mismatch) return Promise.resolve(true);

  return new Promise(function(resolve, reject) {
    var modals = window.Alpine && Alpine.store && Alpine.store('modals');
    if (!modals || !modals.open) {
      reject(new Error('Network confirmation unavailable.'));
      return;
    }
    modals.open('network-guard', {
      title: opts.title || 'Check Network',
      action: opts.action || 'this wallet request',
      networkLabel: info.networkLabel,
      environmentLabel: info.environmentLabel,
      message: (opts.action || 'This wallet request') + ' is about to use ' + info.networkLabel + '.',
      onConfirm: function() { resolve(true); },
      onCancel: function() { reject(new Error('Network confirmation cancelled.')); }
    });
  });
}

export async function authedFetch(url, opts) {
  var resp = await fetch(url, opts);

  // Tier-1 "general" rate limit (rack-attack, rate-limit epic Phase 1): surface
  // the friendly wait modal with a Retry-After countdown and return null so the
  // caller short-circuits with `if (!resp) return;`. "auth"-tier 429s fall
  // through to the caller's own inline UX (they don't open this modal).
  // Debounced like the 401 path so a burst opens one modal.
  if (resp.status === 429 && (resp.headers.get('X-RateLimit-Tier') || 'general') === 'general') {
    if (!_rateLimitHandled) {
      _rateLimitHandled = true;
      setTimeout(function() { _rateLimitHandled = false; }, 1500);
      var retryAfter = parseInt(resp.headers.get('Retry-After'), 10) || 60;
      try {
        var rlModals = window.Alpine && Alpine.store && Alpine.store('modals');
        if (rlModals && rlModals.open) rlModals.open('rate-limit-general', { secondsLeft: retryAfter });
      } catch (e) {}
    }
    return null;
  }

  if (resp.status !== 401) return resp;
  if (_sessionExpiredHandled) return null;
  _sessionExpiredHandled = true;
  setTimeout(function() { _sessionExpiredHandled = false; }, 1500);
  try {
    var session = window.Alpine && Alpine.store && Alpine.store('session');
    if (session) { session.loggedIn = false; session.mode = 'guest'; }
  } catch (e) {}
  try {
    var sm = window.Alpine && Alpine.store && Alpine.store('solanaModal');
    if (sm && sm.close) sm.close();
  } catch (e) {}
  try {
    var modals = window.Alpine && Alpine.store && Alpine.store('modals');
    // Seed every prop the credentials card's controls read. `submitting: null`
    // is the load-bearing one and is NOT the same as omitting the key: the
    // four controls are bound through dotted expressions, and Alpine rewrites
    // an undefined result to the empty string, which SETS a boolean attribute
    // rather than removing it. The binds are hardened with !! as well, so this
    // is the belt to that pair of braces -- it keeps every opener passing the
    // same shape, which is what the gallery mirrors. `mode` is deliberately
    // absent: the navbar openers pass it, but _auth.html.erb never reads it,
    // and this is a re-login rather than a signup.
    if (modals && modals.open) {
      modals.open('auth', {
        step: 'credentials',
        submitting: null,
        formError: '',
        phantomError: '',
        googleError: ''
      });
    }
  } catch (e) {}
  return null;
}

// Poll getSignatureStatuses over HTTP until confirmed/finalized or error.
// Replaces web3.js connection.confirmTransaction, which opens a WebSocket
// signature subscription (auto-derived ws:// at port+1) and surfaces a
// misleading 30s "unknown" timeout. turf-monster has NO RPC proxy — the
// client holds its OWN endpoint (data-solana-rpc-url, from
// Solana::Config.public_rpc_url), so we POST JSON-RPC straight to it. That
// attribute is deliberately NOT the server's keyed endpoint: it is a
// credential-free public/browser URL, so anything the client posts must be
// safe to send over a rate-limited endpoint. ~1.5s interval, ~60s ceiling.
//   confirmed/finalized → resolves with the status object
//   st.err              → throws (tx failed on-chain)
//   timeout             → throws (tx may still land — check explorer)
export async function pollConfirmation(rpcUrl, sig, opts) {
  opts = opts || {};
  var intervalMs = opts.intervalMs || 1500;
  var timeoutMs  = opts.timeoutMs  || 60000;
  var deadline   = Date.now() + timeoutMs;
  // Optional per-poll observer (e.g. the contest-create flow logs each result).
  var onPoll = typeof opts.onPoll === 'function' ? opts.onPoll : null;
  var attempt = 0;

  while (Date.now() < deadline) {
    attempt++;
    var resp = await fetch(rpcUrl, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({
        jsonrpc: '2.0', id: 1, method: 'getSignatureStatuses',
        params: [[sig], { searchTransactionHistory: true }]
      })
    });
    if (resp.ok) {
      var out = await resp.json();
      if (out.error) throw new Error('getSignatureStatuses RPC error: ' + JSON.stringify(out.error));
      var st = out.result && out.result.value && out.result.value[0];
      if (onPoll) { try { onPoll(attempt, st, out); } catch (e) { /* observer must never break polling */ } }
      if (st) {
        if (st.err) throw new Error('Transaction failed on-chain: ' + JSON.stringify(st.err));
        var status = st.confirmationStatus;
        if (status === 'confirmed' || status === 'finalized') return st;
      }
    }
    await new Promise(function(r) { setTimeout(r, intervalMs); });
  }
  throw new Error('Confirmation timed out after ' + (timeoutMs / 1000) + 's (the transaction may still land — check the explorer).');
}
window.pollConfirmation = pollConfirmation;

// Navbar hydrate. The navbar now renders cache-first (the server no longer
// blocks the HTML render on the USDC/USDT/seeds RPCs), so this single call
// fills the live state once the page has painted:
//   (a) the balance pill ([data-balance-display]) — USDC + USDT combined
//   (b) the seeds bar — via the 'navbar-seeds-update' event _seeds_bar listens on
//   (c) $store.session.usdcCents / usdtCents so eligibilityBlocker has live cents
// /admin/usdc_balance returns { balance, usdc, usdt, seeds, level, toward_next,
// progress } — `balance` is the server-combined USDC+USDT sum — and warms the
// server-side caches as a side effect. Every field is guarded — a flaked RPC
// yields null and we leave the prior value in place.
export function refreshBalance() {
  return lockedFetch('balance', '/admin/usdc_balance', {
    headers: { 'Accept': 'application/json' }, cache: 'no-store'
  })
    .then(function(r) { return r && r.json(); })
    .then(function(data) {
      if (!data) return;

      // (a) Balance pill (server-combined USDC + USDT). data.balance is null
      // when BOTH reads flaked — only paint when we got a number, otherwise
      // leave the placeholder for the next poll.
      if (data.balance != null) {
        var formatted = '$' + Math.floor(parseFloat(data.balance));
        document.querySelectorAll('[data-balance-display]').forEach(function(el) {
          el.textContent = formatted;
        });
        // Which face the slot shows ($ amount vs "✨ Free Entry") is one rule,
        // shared with updateNavTokens and the server render.
        applyBalanceSlotRule();
      }

      // (b) Seeds bar — dispatch the same event the entry-confirm flow uses
      // so the bar animates to the new value. Only when seeds are known.
      if (data.seeds != null && data.level != null) {
        try {
          localStorage.setItem('seedsNavbar', JSON.stringify({
            seeds_total: data.seeds,
            level:       data.level,
            toward_next: data.toward_next,
            progress:    data.progress
          }));
        } catch (_) {}
        try {
          window.dispatchEvent(new CustomEvent('navbar-seeds-update', {
            detail: { levelUp: false, level: data.level, progress: data.progress }
          }));
        } catch (_) {}
      }

      // (c) $store.session cents — so the synchronous eligibilityBlocker sees
      // live numbers. Dollars → cents at the boundary; null leaves prior value.
      try {
        var sess = window.Alpine && Alpine.store && Alpine.store('session');
        if (sess) {
          if (data.usdc != null) sess.usdcCents = Math.round(parseFloat(data.usdc) * 100);
          if (data.usdt != null) sess.usdtCents = Math.round(parseFloat(data.usdt) * 100);
        }
      } catch (_) {}

      // (d) wallet tiles — shared fanout, null-guarded per key.
      updateWalletTiles(data);
    })
    .catch(function() {});
}

export function refreshBalanceDelayed(ms) {
  var delay = ms || 10000;
  if (window.showNavSpinner) window.showNavSpinner();
  setTimeout(function() {
    refreshBalance().finally(function() {
      if (window.hideNavSpinner) window.hideNavSpinner();
    });
  }, delay);
}

// Single-call refresh of every on-chain piece the navbar shows: USDC
// balance, free-entry token count, and the seeds bar (count + level +
// progress). Server-side route is /account/session_refresh which fans
// the four Solana RPCs out in parallel; client-side this function then
// drives the existing UI updaters so the navbar converges to truth
// from one place.
//
// Call after any on-chain success path (entry confirm, token mint,
// token consume, withdrawal, payout) instead of stitching together
// refreshBalance + updateNavTokens + seedsNavbar/localStorage by hand.
// Returns a Promise so callers can chain a spinner around it.
export function refreshSession() {
  return lockedFetch('session', '/account/session_refresh', {
    headers: { 'Accept': 'application/json' }, cache: 'no-store'
  })
    .then(function(r) { return r && r.json(); })
    .then(function(data) {
      if (!data) return null;

      // Mirror the on-chain values into $store.session so the synchronous
      // entry-eligibility check (runHoldValidations / confirmEntry) sees
      // fresh state without an extra fetch. Dollars → cents at the boundary.
      // null in the response means "preload RPC flaked" — preserve the
      // store's prior value rather than overwriting with 0 (false-positive
      // block); see ApplicationController#wallet_field_cents.
      try {
        var sess = window.Alpine && Alpine.store && Alpine.store('session');
        if (sess) {
          if (data.usdc != null) sess.usdcCents = Math.round(parseFloat(data.usdc) * 100);
          if (data.usdt != null) sess.usdtCents = Math.round(parseFloat(data.usdt) * 100);
          sess.tokensAvailable = parseInt(data.tokens, 10) || 0;
        }
      } catch (_) {}

      // Balance pill — USDC + USDT combined (matches display_balance +
      // refreshBalance's server-combined data.balance), with the same
      // data-balance-display selector + hide-on-$0-with-token rule so the
      // helpers agree on what the navbar shows. Only paint when at least one
      // read landed — null means "RPC flake", and skipping the paint ONLY
      // when both are null preserves the prior pill value instead of
      // showing a false $0. A single-sided null counts as 0 in the sum.
      try {
        if (data.usdc != null || data.usdt != null) {
          var combined  = (data.usdc != null ? parseFloat(data.usdc) : 0) +
                          (data.usdt != null ? parseFloat(data.usdt) : 0);
          var formatted = '$' + Math.floor(combined);
          var isZero    = formatted === '$0';
          var hasTokens = (parseInt(data.tokens, 10) || 0) > 0;
          document.querySelectorAll('[data-balance-display]').forEach(function(el) {
            el.textContent = formatted;
            if (isZero && hasTokens) el.classList.add('hidden');
            else                     el.classList.remove('hidden');
          });
        }
      } catch (_) {}

      // ✨ token badge — reuse updateNavTokens for the visibility
      // toggle + data-token-count + 'entry-tokens-updated' broadcast.
      try { updateNavTokens(data.tokens); } catch (_) {}

      // Seeds bar — write the canonical localStorage payload the
      // _seeds_bar Alpine factory reads on level-up animations, then
      // dispatch the same 'navbar-seeds-update' event the entry-confirm
      // flow uses so the bar transitions smoothly to the new value
      // instead of snapping on next reload.
      try {
        localStorage.setItem('seedsNavbar', JSON.stringify({
          seeds_total: data.seeds,
          level:       data.level,
          toward_next: data.toward_next,
          progress:    data.progress
        }));
        window.dispatchEvent(new CustomEvent('navbar-seeds-update', {
          detail: { levelUp: false, level: data.level, progress: data.progress }
        }));
      } catch (_) {}

      updateWalletTiles(data);

      return data;
    })
    .catch(function() { return null; });
}

// A level-up mint runs off-request so the entry response never waits on an
// admin-signed Solana transaction. Poll the existing canonical hydrate until
// the server says the milestone is settled; each pass also nudges a missed
// enqueue from a fresh on-chain seed read. Sequential backoff keeps this to at
// most four hydrates and stops as soon as the token is visible.
var _levelUpTokenRefreshGeneration = 0;
export function refreshLevelUpToken() {
  var generation = ++_levelUpTokenRefreshGeneration;
  var delays = [1000, 2500, 5000, 9000];

  function poll(attempt) {
    if (attempt >= delays.length || generation !== _levelUpTokenRefreshGeneration) return;
    setTimeout(function() {
      if (generation !== _levelUpTokenRefreshGeneration) return;
      refreshSession().then(function(data) {
        if (data && data.level_up_token_pending === false) return;
        poll(attempt + 1);
      });
    }, delays[attempt]);
  }

  poll(0);
}

// Wallet tiles — generic fanout: any page can subscribe a balance readout
// to the hydrate calls by tagging an element with
// data-wallet-tile="usdc|usdt|sol|tokens" (/account's Identities row).
// Called from BOTH refreshBalance and refreshSession so every hydrate path
// keeps tiles current (refreshBalance's payload lacks sol/tokens — those
// keys just no-op there). A null field (flaked RPC) leaves the prior render
// in place — server-side "—" or the last live value — never overwrites
// with 0. Deliberately NOT a StateFanout handler: tiles are ephemeral DOM
// (no localStorage state, no event listeners), which is the part of that
// pattern they'd use — this is just the DOM-fill step.
function updateWalletTiles(data) {
  try {
    var tiles = {
      usdc:   data.usdc   != null ? '$' + parseFloat(data.usdc).toFixed(2) : null,
      usdt:   data.usdt   != null ? parseFloat(data.usdt).toFixed(2)       : null,
      sol:    data.sol    != null ? parseFloat(data.sol).toFixed(2)        : null,
      tokens: data.tokens != null ? String(parseInt(data.tokens, 10) || 0) : null
    };
    Object.keys(tiles).forEach(function(key) {
      if (tiles[key] == null) return;
      document.querySelectorAll('[data-wallet-tile="' + key + '"]').forEach(function(el) {
        el.textContent = tiles[key];
      });
    });
  } catch (_) {}
}

// Which face the navbar's balance slot shows. The slot holds two mutually
// exclusive children — the "$1284" amount ([data-balance-display]) and the
// "✨ Free Entry" label ([data-free-entry-label]) — and exactly one rule picks
// between them: a $0 balance held by a user WITH an entry token reads
// "✨ Free Entry", because the amount they can enter for really is zero
// dollars. Everything else shows the amount.
//
// This is the CLIENT half of the rule _navbar.html.erb renders server-side;
// both refreshBalance() and updateNavTokens() call it so the two halves can't
// drift. hasTokens defaults to "is the ✨ badge visible", which is the same
// signal the badge itself is toggled on.
//
// The empty-text case is the cold-cache "loading" render (the server emits no
// "$" at all): keep the slot blank rather than unhiding a lone empty link.
export function applyBalanceSlotRule(hasTokens) {
  var badge = document.querySelector('[data-free-entry-badge]');
  var tokens = (hasTokens === undefined)
    ? !!(badge && !badge.classList.contains('hidden'))
    : (parseInt(hasTokens, 10) || 0) > 0;

  document.querySelectorAll('[data-balance-display]').forEach(function(el) {
    var text = (el.textContent || '').trim();
    var loading = text === '';
    var free = tokens && text === '$0';
    el.classList.toggle('hidden', loading || free);

    var slot = el.closest('[data-balance-slot]');
    var label = slot && slot.querySelector('[data-free-entry-label]');
    if (label) label.classList.toggle('is-active', free);
  });
}

// Toggle the navbar's ✨ free-entry badge based on the new token count.
// Called after a mint (count increases) or a token-funded entry submit
// (count decrements). Also re-applies the balance-slot rule so the live
// state matches the server-side render.
export function updateNavTokens(balance) {
  var n = parseInt(balance, 10) || 0;
  var badge = document.querySelector('[data-free-entry-badge]');
  var wasHidden = !!(badge && badge.classList.contains('hidden'));
  if (badge) {
    if (n > 0) badge.classList.remove('hidden');
    else       badge.classList.add('hidden');
    // Keep data-token-count in sync as a fallback for any consumer that
    // hasn't migrated to the reactive entryTokenBadge factory yet.
    badge.dataset.tokenCount = n;
  }
  // Broadcast so the entryTokenBadge Alpine factory (and any future
  // subscriber) updates its reactive count without polling the dataset.
  try {
    window.dispatchEvent(new CustomEvent('entry-tokens-updated', { detail: { count: n } }));
  } catch (_) {}
  applyBalanceSlotRule(n);
  // A level-up mints the token that UNHIDES this badge, and the count hydrate
  // usually lands after the glow was armed — so replay the glow the moment the
  // badge actually becomes visible, or the celebration plays to an empty slot.
  if (wasHidden && n > 0 && Date.now() < _glowArmedUntil) glowFreeEntryBadge();
}

// Level-up glow on the ✨ badge — three ~1.4s pulses (.free-entry-glow).
//
// A level-up is what MINTS a free entry, so the glow's job is to point at
// where the token landed. Two-step because the mint and the count hydrate are
// not simultaneous: armFreeEntryGlow() plays it now AND leaves a short window
// open, and updateNavTokens replays it if the badge was still hidden and only
// now became visible. Without the window a level-up on a user's FIRST token
// glows a badge the count hydrate has not surfaced yet.
// (The `hidden` class this turns on used to be a no-op on that button — it lost
// the cascade to the inline-flex beside it, so the "still hidden" state this
// window is written around was never actually hidden on screen. An explicit
// unlayered override in app/assets/tailwind/application.css settles that now;
// either way it does not change the ORDERING problem this window exists to
// solve, which is about when the count lands, not about what is painted.)
var GLOW_MS = 4400;
var _glowArmedUntil = 0;
// Handle for the in-flight strip-the-class timer. HELD, because a replay is the
// NORMAL path here, not the rare one: armFreeEntryGlow() fires at +900ms, before
// a first-token badge has been surfaced, and updateNavTokens() replays the glow
// the moment the count hydrate surfaces it. Both land inside GLOW_MS, so an
// unheld timer from play #1 strips play #2 partway through — and the flagship
// first-token celebration is exactly the one that got clipped.
//
// MEASURED, driving two plays 3.0s apart and sampling the painted box-shadow:
// the replay used to run 1340ms; it now runs 4188ms, against 4201ms for a glow
// that plays alone. (Sampled OUTSIDE the disc — .legendary-badge pans a gradient
// across it forever, so a probe that includes the disc can never tell the glow
// from the passage of time.)
var _glowTimer = null;

export function glowFreeEntryBadge() {
  var badge = document.querySelector('[data-free-entry-badge]');
  if (!badge) return;
  // Cancel the previous play's strip BEFORE starting this one, or it fires
  // mid-replay and truncates the animation this call just restarted.
  if (_glowTimer) { clearTimeout(_glowTimer); _glowTimer = null; }
  badge.classList.remove('free-entry-glow'); // reset so a 2nd level-up re-fires
  void badge.offsetWidth;                    // force reflow
  badge.classList.add('free-entry-glow');
  _glowTimer = setTimeout(function() {
    badge.classList.remove('free-entry-glow');
    _glowTimer = null;
  }, GLOW_MS);
}

// Arm + play. windowMs is how long a later token-count hydrate may still
// replay the glow (see updateNavTokens).
export function armFreeEntryGlow(windowMs) {
  _glowArmedUntil = Date.now() + (windowMs || 20000);
  glowFreeEntryBadge();
}

// Fires the .free-entry-punch CSS animation on the ✨ badge — wired
// from confirmEntry's success path when the server reports the entry
// was funded by a consumed token (data.token_consumed === true).
export function animateFreeEntryBadge() {
  var badge = document.querySelector('[data-free-entry-badge]');
  if (!badge) return;
  badge.classList.remove('free-entry-punch'); // reset so a 2nd consume re-fires
  void badge.offsetWidth;                     // force reflow
  badge.classList.add('free-entry-punch');
  setTimeout(function() { badge.classList.remove('free-entry-punch'); }, 700);
}

// Read a layer tier at runtime. canvas-confetti takes zIndex as a NUMBER, so
// these two bursts kept a bare 9999 after _alpine_factories converted its
// identical pair — same magic number, one directory the drift scan did not
// glob. --z-alert is the tier those two now read: above --z-modal, so a
// celebration fired from an open modal is not hidden by it.
function zTier(name, fallback) {
  var v = parseInt(getComputedStyle(document.documentElement).getPropertyValue(name).trim(), 10);
  return Number.isFinite(v) ? v : fallback;
}

// Confetti burst that originates from the ✨ Entry badge in the navbar.
// Used instead of the centered fireSuccessConfetti for token-flow
// celebrations (mint + entry confirmed) so the streamers shoot out of
// the badge the user just earned / consumed. Falls back to the top-
// right of the viewport when the badge isn't on screen (e.g. after a
// consume that dropped the count to 0 and hid the badge).
//
// THAT FALLBACK ONLY BECAME REACHABLE with the entry-badge cascade fix. While
// `.hidden` lost to the inline-flex beside it the badge always reported a live
// 20x20 rect, so `hidden` here was permanently false and a consume-to-zero
// burst fired from a disc that was about to stop being painted. It now takes
// the corner branch, which is what the sentence above always claimed.
export function fireConfettiFromBadge() {
  if (typeof confetti === 'undefined') return;
  var badge  = document.querySelector('[data-free-entry-badge]');
  var rect   = badge && badge.getBoundingClientRect();
  var hidden = !rect || (rect.width === 0 && rect.height === 0);
  var origin = hidden
    ? { x: 0.92, y: 0.08 } // approximate badge slot in the top-right nav
    : {
        x: (rect.left + rect.width  / 2) / window.innerWidth,
        y: (rect.top  + rect.height / 2) / window.innerHeight
      };
  var colors = window.CONFETTI_COLORS || ['#4BAF50', '#8E82FE', '#06D6A0', '#FF7C47', '#FFD700', '#00BFFF', '#FF6B9D', '#C084FC'];
  // Radial pop from the badge center — spread:360 fires particles in
  // every direction (up, down, sideways), low startVelocity + low
  // gravity keep them clustered around the badge rather than blasting
  // off-screen. Reads like an "out of the ticket" celebration.
  confetti({ particleCount: 90, angle: 90, spread: 360, origin: origin, colors: colors, zIndex: zTier('--z-alert', 300), startVelocity: 22, gravity: 0.55, ticks: 180, scalar: 0.9 });
  // Smaller follow-up shell, even tighter, for layered texture.
  setTimeout(function() {
    confetti({ particleCount: 45, angle: 90, spread: 360, origin: origin, colors: colors, zIndex: zTier('--z-alert', 300), startVelocity: 14, gravity: 0.75, ticks: 140, scalar: 0.7 });
  }, 160);
}

// Confetti color palette — shared across solana modal & seeds bar
export const CONFETTI_COLORS = ['#4BAF50', '#8E82FE', '#06D6A0', '#FF7C47', '#FFD700', '#00BFFF', '#FF6B9D', '#C084FC'];

// Attach to window for backward compatibility with inline scripts/onclick handlers
window.lockedFetch = lockedFetch;
window.authedFetch = authedFetch;
window.solanaNetworkInfo = solanaNetworkInfo;
window.confirmSolanaNetworkIntent = confirmSolanaNetworkIntent;
window.refreshBalance = refreshBalance;
window.refreshBalanceDelayed = refreshBalanceDelayed;
window.refreshSession = refreshSession;
window.refreshLevelUpToken = refreshLevelUpToken;
// fireConfettiFromModal was removed (it had no call sites). Its exact radial
// card-burst now lives in studio-engine as window.studioConfetti.burst(el) — a
// faithful, byte-for-byte port (see studio/studio_confetti.js). Use that.

// Synchronous entry-eligibility check against the running $store.session.
// Returns null if the viewer can submit, or { reason, mode, data } describing
// the blocker. The board's hold + submit paths use this immediately after
// their loggedIn / isGuest gate so we never let the user complete a hold
// against state we already know will fail server-side.
//
// neededCents is the contest entry fee. session is Alpine.store('session').
// opts.acceptsUsdt (default false): pass it true only for contests whose
// on-chain entry_fee_by_currency funded slot 1 (Contest#accepts_usdt) — then
// web3 eligibility is either-or (USDC OR USDT covers the fee). Contests
// created before 2026-06-10 have an immutable zero USDT fee, so USDT funds
// must NOT satisfy them (the program would reject with EntryFeeNotSet 6027).
export function eligibilityBlocker(session, neededCents, opts) {
  if (!session) return null;            // store missing — let server decide
  if (!session.loggedIn) return { reason: 'not_logged_in', mode: 'guest', data: {} };

  // First name — the FIRST validation of the hold (operator call, 2026-08-15),
  // ahead of age, wallet and funding, so the name is collected before the user
  // is asked for anything heavier. Mirrors the onboarding chain's order, which
  // also opens on this question.
  //
  // UNLIKE the gates below it, this one has no server-side twin: a first name is
  // marketing copy for emails, not a compliance or capability property, so
  // ContestsController#enter does NOT refuse without it. That is the deliberate
  // difference — the age and wallet gates keep their server teeth because an
  // entry that slips past them is an illegal or unsignable entry, while one that
  // slips past this is merely an entry from someone we will address by username.
  if (session.firstNameRequired) {
    return { reason: 'first_name_required', mode: session.mode || 'guest', data: {} };
  }

  // Age gate (ENABLE_AGE_GATE) — checked BEFORE tokens/balance and even before
  // the free-contest short-circuit, so the DOB modal fires ahead of the Get
  // Entry Tokens modal and applies to every contest. Server re-checks.
  if (session.ageGateRequired && !session.ageVerified) {
    return { reason: 'age_required', mode: session.mode || 'guest', data: {} };
  }

  // Web3-only onboarding — BEFORE the free-contest short-circuit on purpose.
  // Entry is an on-chain instruction signed against the user's wallet, so an
  // account with no wallet can't enter a FREE contest either; gating this
  // behind the fee check would let a wallet-less user hold-to-confirm a free
  // entry straight into a server-side refusal. Server re-checks (the
  // authoritative gate is ContestsController#enter).
  if (session.walletSetupRequired) {
    return { reason: 'wallet_setup_required', mode: session.mode || 'web2', data: {} };
  }

  if ((neededCents | 0) <= 0) return null;  // free contest

  if (session.mode === 'web2') {
    // Unified web2 funding (operator spec 2026-06-13): ENTRY TOKEN first (incl.
    // seed-earned free entries — /enter consumes an EntryTokenAccount before any
    // USDC), then USDC when ENABLE_WEB2_USDC_ENTRY is on (server-signs
    // enter_contest). USDT is never offered to web2 (payouts are USDC). Block
    // only when NO enabled method covers the fee.
    if ((session.tokensAvailable | 0) >= 1) return null;
    if (session.web2UsdcEntry) {
      // LAYERING (2026-06-13) — this synchronous blocker is a fast FIRST pass:
      //  - usdcCents is a KNOWN number < fee  → no_funding below (caught here).
      //  - usdcCents is null (UNKNOWN — a brand-new managed wallet has no USDC
      //    ATA yet, OR a cold navbar cache / RPC flake) → fail OPEN (return
      //    null) so we never FALSE-block a funded user whose balance simply
      //    hasn't hydrated. The genuinely-unfunded null case is covered by the
      //    AUTHORITATIVE hold-window server check (the board's beginFundingCheck
      //    → POST check_funding, awaited in confirmEntry) plus the server
      //    safety-net (resolve_web2_entry_funding!), so a $0 fresh wallet lands
      //    on the Top Up Wallet — never a doomed on-chain "0x1" sim attempt.
      if (session.usdcCents == null) return null;
      if ((session.usdcCents | 0) >= neededCents) return null;
    }
    return { reason: 'no_funding', mode: 'web2', data: {} };
  }
  if (session.mode === 'web3') {
    // ENTRY TOKEN first — the same priority the web2 branch above applies, and
    // the same order the server now follows for Phantom (ContestsController#
    // prepare_entry builds enter_contest_with_token when this wallet holds an
    // unconsumed token, else the currency transfer). Before that wiring existed
    // this check could NOT live here: a token-holding wallet with no USDC would
    // have been waved past the blocker into an entry that charged USDC it did
    // not have. Now the token IS the funding, so a balance of zero is no reason
    // to block.
    if ((session.tokensAvailable | 0) >= 1) return null;

    // Fail open when balances are unknown — the server-side enter is the
    // authoritative gate. preload_navbar_solana_data's balances_thread
    // returns nil on RPC flake, which client_session_payload now emits
    // as null (not 0). Without this branch the falsy-coalesce would
    // treat a flaky page-load as "user has $0" and false-positive block.
    if (session.usdcCents == null && session.usdtCents == null) return null;
    var usdc = session.usdcCents | 0;
    var usdt = session.usdtCents | 0;
    var acceptsUsdt = !!(opts && opts.acceptsUsdt);
    if (usdc >= neededCents) return null;
    if (acceptsUsdt && usdt >= neededCents) return null;
    return { reason: 'insufficient_balance', mode: 'web3',
             data: { usdcCents: usdc, usdtCents: usdt, neededCents: neededCents | 0 } };
  }
  return null;
}
window.eligibilityBlocker = eligibilityBlocker;

window.updateNavTokens = updateNavTokens;
window.applyBalanceSlotRule = applyBalanceSlotRule;
window.animateFreeEntryBadge = animateFreeEntryBadge;
window.glowFreeEntryBadge = glowFreeEntryBadge;
window.armFreeEntryGlow = armFreeEntryGlow;
window.fireConfettiFromBadge = fireConfettiFromBadge;
window.CONFETTI_COLORS = CONFETTI_COLORS;
