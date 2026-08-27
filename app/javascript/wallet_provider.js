// Wallet Provider Abstraction
// Abstracts wallet operations behind a common interface so Phantom, keypair-based
// bots, and future providers all share the same API surface.

// --- Sign In With Solana (solana:signIn) ---
//
// WHY: `connect()` then `signMessage()` costs the user TWO wallet approvals for
// one intent. The Wallet Standard's `solana:signIn` feature does both in one —
// the wallet composes the SIWS message itself, connects, and signs, returning
// the account plus the exact bytes it signed. Every provider below advertises
// support via `supportsSignIn()` and normalizes its output to ONE shape:
//
//   { address: <base58 String>, signedMessage: <Uint8Array>, signature: <Uint8Array> }
//
// CRITICAL CONTRACT: callers MUST verify against `signedMessage` — the bytes the
// wallet actually signed — never a locally rebuilt string. A wallet is free to
// add URI / Version / Chain ID / Issued At lines, and a rebuilt string would not
// match the signature. See solanaConnectAndVerify in layouts/application.html.erb.

// Minimal SIWS message, used by providers that compose the message themselves
// (the keypair test provider) rather than delegating to a real wallet. Matches
// the shape a Wallet Standard wallet emits for the same input.
//
// Byte-identical to the hand-rolled fallback message in solanaConnectAndVerify
// IN LOGIN MODE ONLY. Link mode diverges on purpose: the fallback writes
// "User-ID: <id>" as its own paragraph, while the SIWS statement inlines it as
// "(User-ID: <id>)" because the spec's grammar puts `statement` on one line.
// Both satisfy the server's `message.include?("User-ID: <id>")`.
function buildSiwsMessage(input, address) {
  return (input.domain || '') + ' wants you to sign in with your Solana account:\n' +
         address + '\n\n' +
         (input.statement || '') + '\n\n' +
         'Nonce: ' + (input.nonce || '');
}

// Normalize a signIn output across the Wallet Standard shape
// ({ account: { address }, ... }) and the legacy injected-provider shape
// ({ address, ... }, where address may be a PublicKey object). Written
// defensively on purpose: the injected Phantom provider's exact return shape is
// version-dependent, and guessing wrong here would break sign-in rather than
// degrade it. Anything unrecognized throws, which routes the caller to its
// fallback path instead of posting a malformed payload.
function normalizeSignInOutput(out) {
  var o = Array.isArray(out) ? out[0] : out;
  if (!o) throw new Error('signIn returned no output');

  var address = null;
  if (o.account && o.account.address) {
    address = o.account.address;
  } else if (o.address) {
    address = (typeof o.address === 'string') ? o.address : o.address.toBase58();
  }
  if (!address) throw new Error('signIn output carried no account address');
  if (!o.signedMessage) throw new Error('signIn output carried no signedMessage');
  if (!o.signature) throw new Error('signIn output carried no signature');

  return {
    address: address,
    signedMessage: new Uint8Array(o.signedMessage),
    signature: new Uint8Array(o.signature),
    _account: o.account || null
  };
}


// --- PhantomProvider ---
// Wraps window.phantom.solana. Delegates all calls to the browser extension.
var PhantomProvider = {
  name: 'phantom',

  isAvailable: function() {
    return !!(window.phantom && window.phantom.solana && window.phantom.solana.isPhantom);
  },

  _provider: function() {
    return window.phantom && window.phantom.solana;
  },

  connect: function(opts) {
    var p = this._provider();
    if (!p) return Promise.reject(new Error('Phantom not available'));
    return p.connect(opts);
  },

  signMessage: function(encoded, encoding) {
    var p = this._provider();
    if (!p) return Promise.reject(new Error('Phantom not available'));
    return p.signMessage(encoded, encoding);
  },

  supportsSignIn: function() {
    var p = this._provider();
    return !!(p && typeof p.signIn === 'function');
  },

  signIn: function(input) {
    var p = this._provider();
    if (!p || typeof p.signIn !== 'function') {
      return Promise.reject(new Error('Phantom does not support signIn'));
    }
    return p.signIn(input).then(normalizeSignInOutput);
  },

  signTransaction: function(tx) {
    var p = this._provider();
    if (!p) return Promise.reject(new Error('Phantom not available'));
    var guard = window.confirmSolanaNetworkIntent
      ? window.confirmSolanaNetworkIntent({ action: 'Sign transaction' })
      : Promise.resolve(true);
    return guard.then(function() { return p.signTransaction(tx); });
  },

  on: function(event, callback) {
    var p = this._provider();
    if (p && p.on) p.on(event, callback);
  },

  disconnect: function() {
    var p = this._provider();
    if (!p) return Promise.resolve();
    return p.disconnect();
  },

  get publicKey() {
    var p = this._provider();
    return p ? p.publicKey : null;
  }
};


// --- KeypairProvider ---
// Loads an Ed25519 keypair from window.__WALLET_KEYPAIR_SECRET (Uint8Array of 64-byte secret key).
// Uses tweetnacl for signing. Designed for Playwright tests and bot agents.
var KeypairProvider = {
  name: 'keypair',
  _keypair: null,
  _publicKeyObj: null,

  isAvailable: function() {
    return !!(window.__WALLET_KEYPAIR_SECRET);
  },

  _ensureKeypair: function() {
    if (this._keypair) return Promise.resolve(this._keypair);
    var secret = window.__WALLET_KEYPAIR_SECRET;
    if (!secret) return Promise.reject(new Error('No keypair secret set'));

    var self = this;

    // tweetnacl should already be loaded on the page (CDN in head)
    if (typeof nacl !== 'undefined' && nacl.sign) {
      // secret is the full 64-byte secretKey (seed + pubkey)
      self._keypair = { publicKey: secret.slice(32), secretKey: secret };
      self._publicKeyObj = self._makePublicKey(self._keypair.publicKey);
      return Promise.resolve(self._keypair);
    }

    // Lazy-load tweetnacl if not present
    return new Promise(function(resolve, reject) {
      var s = document.createElement('script');
      s.src = 'https://cdn.jsdelivr.net/npm/tweetnacl@1.0.3/nacl-fast.min.js';
      s.onload = function() {
        self._keypair = { publicKey: secret.slice(32), secretKey: secret };
        self._publicKeyObj = self._makePublicKey(self._keypair.publicKey);
        resolve(self._keypair);
      };
      s.onerror = reject;
      (document.head || document.documentElement).appendChild(s);
    });
  },

  _makePublicKey: function(bytes) {
    return {
      toBytes: function() { return bytes; },
      toBase58: function() { return window.encodeBase58(bytes); },
      toString: function() { return window.encodeBase58(bytes); }
    };
  },

  connect: function() {
    var self = this;
    return this._ensureKeypair().then(function() {
      return { publicKey: self._publicKeyObj };
    });
  },

  signMessage: function(encoded) {
    return this._ensureKeypair().then(function(kp) {
      var signature = nacl.sign.detached(encoded, kp.secretKey);
      return { signature: signature };
    });
  },

  // Stands in for a real wallet's solana:signIn so the e2e suite exercises the
  // CONSOLIDATED path, not just the fallback. Without this the new code would
  // ship with zero browser coverage — every test provider would take the old
  // two-step branch and the signIn branch would never execute in CI.
  supportsSignIn: function() { return true; },

  signIn: function(input) {
    var self = this;
    return this._ensureKeypair().then(function(kp) {
      var address = window.encodeBase58(kp.publicKey);
      var encoded = new TextEncoder().encode(buildSiwsMessage(input, address));
      return {
        address: address,
        signedMessage: encoded,
        signature: nacl.sign.detached(encoded, kp.secretKey),
        _account: null
      };
    });
  },

  signTransaction: function(tx) {
    return this._ensureKeypair().then(function(kp) {
      // solanaWeb3 must be loaded on the page
      var solKp = solanaWeb3.Keypair.fromSecretKey(kp.secretKey);
      tx.partialSign(solKp);
      return tx;
    });
  },

  on: function() {
    // No-op — keypair provider doesn't emit events
  },

  disconnect: function() {
    this._keypair = null;
    this._publicKeyObj = null;
    return Promise.resolve();
  },

  get publicKey() {
    return this._publicKeyObj || null;
  }
};


// --- Wallet Standard discovery (the multi-wallet hub) ---
// Implements the @wallet-standard/app handshake in plain JS — no bundler/npm.
// Phantom, Solflare, Backpack, and any other compliant wallet register
// themselves here. Each is normalized into the SAME provider interface the
// rest of the app already uses (connect / signMessage / signTransaction /
// on('accountChanged') / disconnect / publicKey), so the SIWS flow is unchanged.
var _wsWallets = [];

function _wsHasSolana(wallet) {
  return !!(wallet && wallet.chains && wallet.chains.some(function(c) { return c.indexOf('solana:') === 0; }));
}

// Normalize a Wallet Standard `Wallet` into our provider interface. The byte
// contract is preserved: signMessage takes the same Uint8Array the SIWS code
// produces with TextEncoder, and returns { signature: Uint8Array } — exactly
// what encodeBase58() expects, so /auth/solana/verify needs no change.
function _makeWsAdapter(wallet) {
  var account = null;
  function pubObj(acct) {
    return {
      toBytes:  function() { return acct.publicKey; },
      toBase58: function() { return acct.address; },
      toString: function() { return acct.address; }
    };
  }
  return {
    name: wallet.name,
    icon: wallet.icon, // data: URI provided by the wallet — rendered in the hub
    _raw: wallet,
    isAvailable: function() { return true; },
    connect: function(opts) {
      var feat = wallet.features['standard:connect'];
      var silent = !!(opts && opts.onlyIfTrusted);
      return feat.connect(silent ? { silent: true } : {}).then(function(res) {
        var accts = (res && res.accounts) || wallet.accounts || [];
        account = accts[0] || null;
        if (!account) throw new Error('No account authorized');
        return { publicKey: pubObj(account) };
      });
    },
    signMessage: function(encoded /*, encoding ignored — WS always takes raw bytes */) {
      if (!account) return Promise.reject(new Error('Wallet not connected'));
      return wallet.features['solana:signMessage'].signMessage({ account: account, message: encoded })
        .then(function(outputs) {
          var out = Array.isArray(outputs) ? outputs[0] : outputs;
          return { signature: out.signature };
        });
    },
    supportsSignIn: function() { return !!wallet.features['solana:signIn']; },
    signIn: function(input) {
      var feat = wallet.features['solana:signIn'];
      if (!feat) return Promise.reject(new Error('Wallet does not support signIn'));
      return feat.signIn(input).then(function(outputs) {
        var norm = normalizeSignInOutput(outputs);
        // signIn CONNECTS as well as signs, so adopt the account it returned —
        // otherwise a later signTransaction on this same adapter would reject
        // with "Wallet not connected" despite the user having just signed in.
        if (norm._account) account = norm._account;
        return norm;
      });
    },
    signTransaction: function(tx) {
      var feat = wallet.features['solana:signTransaction'];
      if (!feat) return Promise.reject(new Error('Wallet cannot sign transactions'));
      if (!account) return Promise.reject(new Error('Wallet not connected'));
      var guard = window.confirmSolanaNetworkIntent
        ? window.confirmSolanaNetworkIntent({ action: 'Sign transaction' })
        : Promise.resolve(true);
      return guard.then(function() {
        var wire = tx.serialize({ requireAllSignatures: false, verifySignatures: false });
        return feat.signTransaction({ account: account, transaction: new Uint8Array(wire) });
      })
        .then(function(outputs) {
          var out = Array.isArray(outputs) ? outputs[0] : outputs;
          return solanaWeb3.Transaction.from(out.signedTransaction);
        });
    },
    on: function(event, cb) {
      // Normalize WS 'standard:events' change → the legacy events the wallet
      // watcher store listens for.
      //
      // 'disconnect' IS translated here, and that is the point of this branch.
      // Wallet Standard has no separate disconnect event: an empty accounts
      // array IS the disconnect. Before this, `on` opened with
      // `if (event !== 'accountChanged') return;` and dropped every other event
      // on the floor — so the disconnect subscription in solana_stores.js was a
      // SILENT NO-OP on this adapter, which is the steady state for a modern
      // Phantom after the 'wallet-provider:registered' swap. It worked only on
      // the legacy provider, whose own `on` forwards any event.
      if (event !== 'accountChanged' && event !== 'disconnect') return;
      var feat = wallet.features['standard:events'];
      if (!feat || !feat.on) return;
      feat.on('change', function(props) {
        // A change event only carries the keys that changed; only react when
        // it actually includes accounts (an empty array = disconnect → null).
        if (props && 'accounts' in props) {
          account = (props.accounts && props.accounts[0]) || null;
          if (event === 'disconnect') {
            // Only the transition to NO account is a disconnect. A switch to a
            // different account is an accountChanged, and firing disconnect for
            // it would tear down a session the user never left.
            if (!account) cb();
          } else {
            cb(account ? pubObj(account) : null);
          }
        }
      });
    },
    disconnect: function() {
      var feat = wallet.features['standard:disconnect'];
      account = null;
      return (feat && feat.disconnect) ? feat.disconnect() : Promise.resolve();
    },
    get publicKey() { return account ? pubObj(account) : null; }
  };
}

function _wsRegister(wallet) {
  if (!wallet || !wallet.features) return;
  if (!_wsHasSolana(wallet)) return;
  // Require the features the SIWS sign-in flow needs.
  if (!wallet.features['standard:connect'] || !wallet.features['solana:signMessage']) return;
  if (_wsWallets.some(function(a) { return a._raw === wallet; })) return; // de-dupe
  var adapter = _makeWsAdapter(wallet);
  _wsWallets.push(adapter);
  try {
    window.dispatchEvent(new CustomEvent('wallet-provider:registered', {
      detail: { name: adapter.name }
    }));
  } catch (e) { /* registration still succeeds in non-browser test contexts */ }
}

// The app's side of the handshake. `register` is what wallets call (directly
// for late wallets via our app-ready broadcast, or via the callback they
// dispatch when they loaded before us).
var _wsApi = {
  version: '1.0.0',
  register: function() {
    for (var i = 0; i < arguments.length; i++) _wsRegister(arguments[i]);
    return function() {}; // unregister no-op
  }
};

(function _initWalletStandard() {
  try {
    // Wallets that loaded BEFORE us dispatched register-wallet with a callback
    // expecting our api ( ({register}) => register(wallet) ).
    window.addEventListener('wallet-standard:register-wallet', function(e) {
      if (typeof e.detail === 'function') { try { e.detail(_wsApi); } catch (err) {} }
    });
    // Announce readiness so wallets present now (and any that load later)
    // call _wsApi.register with themselves.
    window.dispatchEvent(new CustomEvent('wallet-standard:app-ready', { detail: _wsApi }));
  } catch (e) { /* non-browser / SSR — ignore */ }
})();


// --- Registry ---
// window.walletProvider — detect best provider, get by name, list for the hub
var walletProvider = {
  // Single "best" provider for call sites that don't let the user choose
  // (silent re-auth, the legacy single-button connect). Keypair wins for tests;
  // legacy Phantom keeps its existing precedence; else the first discovered
  // Wallet Standard wallet.
  detect: function() {
    if (KeypairProvider.isAvailable()) return KeypairProvider;
    if (PhantomProvider.isAvailable()) return PhantomProvider;
    if (_wsWallets.length) return _wsWallets[0];
    return null;
  },

  // Get a specific provider by name (used by the hub picker). Matches a
  // discovered Wallet Standard wallet by display name (case-insensitive),
  // with 'phantom'/'keypair' legacy aliases.
  get: function(name) {
    if (!name) return null;
    var lower = ('' + name).toLowerCase();
    if (lower === 'keypair') return KeypairProvider;
    for (var i = 0; i < _wsWallets.length; i++) {
      if (_wsWallets[i].name && _wsWallets[i].name.toLowerCase() === lower) return _wsWallets[i];
    }
    if (lower === 'phantom' && PhantomProvider.isAvailable()) return PhantomProvider; // legacy fallback
    return null;
  },

  // Connectable wallets for the hub picker. CALL AT CLICK TIME — the list
  // fills in asynchronously as wallets register after module load, so reading
  // it during x-data init would return an empty list.
  available: function() {
    var list = _wsWallets.slice();
    // Surface a legacy Phantom extension that didn't register via Wallet
    // Standard (older builds) so it never silently drops out of the hub.
    var hasPhantom = list.some(function(a) { return a.name && a.name.toLowerCase() === 'phantom'; });
    if (!hasPhantom && PhantomProvider.isAvailable()) list.push(PhantomProvider);
    return list;
  },

  // True if any provider is available
  isAvailable: function() {
    return KeypairProvider.isAvailable() || PhantomProvider.isAvailable() || _wsWallets.length > 0;
  },

  // Check if mobile (no extension expected)
  isMobile: function() {
    return /Android|iPhone|iPad|iPod/i.test(navigator.userAgent) ||
           (navigator.maxTouchPoints > 1 && /Macintosh/.test(navigator.userAgent));
  }
};

window.walletProvider = walletProvider;
