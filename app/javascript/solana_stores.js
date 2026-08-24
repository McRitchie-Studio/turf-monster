// Solana Alpine stores — module supplement
// The solanaModal store, solanaConnectAndVerify/postMagicLink, and
// fireSuccessConfetti are registered inline in application.html.erb (before
// Alpine) to avoid module timing issues.
// This module registers the wallet watcher store (fine to load late).

function registerWalletStore() {
  if (typeof Alpine === 'undefined') return false;
  if (Alpine.store('wallet')) return true;

  // THE WATCHED PROVIDER LIVES HERE, IN THE CLOSURE — NOT ON THE STORE.
  //
  // `Alpine.store(name, obj)` wraps obj in a reactive Proxy, and reading an
  // object-valued property back returns a PROXY OF the value, not the value.
  // So `this._provider = provider` stores the raw provider and `this._provider`
  // hands back a proxy — `proxy === raw` is false, forever. Every identity
  // check against a provider captured in a listener closure therefore FAILED,
  // ALWAYS: the live `accountChanged` listener discarded every event it ever
  // received, and the only thing that opened the handoff was the focus
  // reconcile, which calls _handleAccountChanged directly.
  //
  // MEASURED IN CHROME, 2026-08-24: a real Phantom account switch fired
  // `accountChanged` at 11:08:01 and the modal did not appear until the user
  // clicked the page at 11:08:13. Twelve seconds, and unbounded in principle —
  // a user who switches accounts in Phantom's side panel and keeps reading sees
  // nothing at all.
  //
  // A closure variable is not proxied, so identity here means what it says.
  // `_provider` stays on the store as a debugging mirror (it is what a console
  // probe reads); NOTHING may compare against it.
  var watched = null;

  // Providers already bound, so a listener is attached ONCE per object. While
  // the identity check could never pass, the "same provider" early return could
  // never be taken either — so every focus and every one of the 40 discovery
  // ticks re-entered the bind branch and stacked another dead listener.
  var bound = (typeof WeakSet === 'function') ? new WeakSet() : null;

  // --- Wallet Watcher Store ---
  // Detects wallet switches and hands the user into an explicit re-auth flow.
  Alpine.store('wallet', {
    address: null,
    watching: false,
    pendingAddress: null,
    _provider: null,
    _discoveryTimer: null,

    init: function() {
      if (this.watching) return;

      // Only WEB3 (live Phantom-signature) sessions may engage Phantom. A
      // web2/managed/guest user has a server-held keypair (or no wallet), so
      // probing Phantom — even silently with onlyIfTrusted — pops the unlock
      // prompt on an installed+previously-trusted extension on EVERY page
      // load. Gate on the canonical session mode (the #session-context JSON,
      // the same source Alpine.store('session') hydrates from) read directly,
      // so this is correct regardless of alpine:init store-registration order.
      if (!this._isWeb3Session()) return;

      var serverAddr = this._serverAddress();
      if (!serverAddr) return;

      var self = this;
      this.watching = true;

      // Prefer the wallet BRAND that authenticated this session. Phantom can
      // expose both a legacy injected provider and a Wallet Standard adapter;
      // detect() is intentionally generic and can choose the legacy object
      // before the adapter that actually signed has registered.
      this._watchPreferredProvider(false);

      // Wallet Standard registration is asynchronous. Upgrade immediately
      // when its adapter arrives, and keep a short discovery window for legacy
      // injected providers that appear after our module executes.
      window.addEventListener('wallet-provider:registered', function() {
        self._watchPreferredProvider(false);
      });
      this._scheduleProviderDiscovery();

      // Browser-extension events are best-effort, especially while Chrome's
      // wallet side panel owns focus. Re-read the injected provider when Turf
      // Monster regains focus so a missed event cannot strand the navbar on
      // one account while Phantom shows another.
      window.addEventListener('focus', function() {
        self._watchPreferredProvider(true);
      });
    },

    _serverAddress: function() { return document.body.dataset.walletAddress || ''; },

    _sessionProviderName: function() { return document.body.dataset.walletProvider || ''; },

    _preferredProvider: function() {
      var registry = window.walletProvider;
      if (!registry) return null;
      var providerName = this._sessionProviderName();
      var named = providerName && registry.get ? registry.get(providerName) : null;
      return named || (registry.detect ? registry.detect() : null);
    },

    _watchPreferredProvider: function(reconcileExisting) {
      var provider = this._preferredProvider();
      if (!provider) return false;

      // `watched`, never `this._provider` — see the note above the store.
      if (watched === provider) {
        if (reconcileExisting) this._reconcileProvider(provider, true);
        return true;
      }

      watched = provider;
      this._provider = provider; // debugging mirror only; never compared
      var self = this;
      if (provider.on && !(bound && bound.has(provider))) {
        if (bound) bound.add(provider);
        provider.on('accountChanged', function(publicKey) {
          // A late Wallet Standard registration can replace a legacy Phantom
          // interface. Ignore events from the superseded interface — and note
          // this compares the CLOSURE, so a superseded provider stays ignored
          // and the current one is actually heard.
          if (watched === provider) self._handleAccountChanged(publicKey);
        });
      }
      this._reconcileProvider(provider, true);
      return true;
    },

    _scheduleProviderDiscovery: function() {
      if (this._discoveryTimer) return;
      var self = this;
      var attempts = 0;
      function discover() {
        self._discoveryTimer = null;
        self._watchPreferredProvider(false);
        attempts += 1;
        if (attempts < 40 && self.watching) {
          self._discoveryTimer = setTimeout(discover, 100);
        }
      }
      this._discoveryTimer = setTimeout(discover, 100);
    },

    // True only for a live Phantom-signature (web3) session. Reads the
    // canonical session mode from the server-rendered #session-context JSON
    // (SessionContext#to_h → { mode: 'web3' | 'web2' | 'guest', ... }) rather
    // than the Alpine session store, so it doesn't depend on which store
    // registered first during alpine:init. Falls back to the store, then to
    // false (never engage Phantom on unknown/managed sessions).
    _isWeb3Session: function() {
      try {
        var el = document.getElementById('session-context');
        if (el) return JSON.parse(el.textContent).mode === 'web3';
      } catch (e) { /* fall through to store / safe default */ }
      var s = (typeof Alpine !== 'undefined' && Alpine.store) ? Alpine.store('session') : null;
      return !!(s && s.mode === 'web3');
    },

    _reconcileProvider: function(provider, connectSilently) {
      var self = this;
      var current = provider && provider.publicKey;
      if (current) {
        this._handleAccountChanged(current);
        return Promise.resolve();
      }
      if (!connectSilently || !provider || !provider.connect) return Promise.resolve();
      return provider.connect({ onlyIfTrusted: true })
        .then(function(resp) {
          if (resp && resp.publicKey) self._handleAccountChanged(resp.publicKey);
        })
        .catch(function() {}); // Intentional: wallet not yet approved by user — no action needed
    },

    _reauthing: false,

    _handleAccountChanged: function(publicKey) {
      // A null event occurs during some ordinary Phantom account switches and
      // on extension lock/disconnect. Neither invalidates the signed Rails
      // session, so wait for a concrete account instead of logging out.
      if (!publicKey) return;

      var newAddr = publicKey.toBase58();
      this.address = newAddr;

      // Switching back is the safe escape from the blocking handoff: the
      // browser wallet and the authenticated server session agree again.
      if (newAddr === this._serverAddress()) {
        this.pendingAddress = null;
        try {
          var currentModals = window.Alpine && Alpine.store && Alpine.store('modals');
          if (currentModals && currentModals.isOpen && currentModals.isOpen('wallet-changed')) {
            currentModals.close();
          }
        } catch (e) { /* the next concrete account event will reconcile again */ }
        return;
      }

      this._notifySwitch(newAddr);
    },

    _providerLabel: function() {
      try {
        var provider = watched || this._preferredProvider();
        var name = provider && provider.name;
        if (!name) return 'Wallet';
        return name.charAt(0).toUpperCase() + name.slice(1);
      } catch (e) {
        return 'Wallet';
      }
    },

    _notifySwitch: function(pubkeyB58) {
      if (!pubkeyB58 || pubkeyB58 === this._serverAddress()) return;
      this.pendingAddress = pubkeyB58;
      try {
        var modals = window.Alpine && Alpine.store && Alpine.store('modals');
        if (!modals) return;
        if (modals.isOpen && modals.isOpen('wallet-changed')) {
          // Phantom can move through more than one account while this card is
          // open. Keep the displayed/signable address aligned with the latest
          // concrete event rather than signing stale props.
          var current = modals.current && modals.current();
          if (current && current.id === 'wallet-changed') {
            current.props.newAddress = pubkeyB58;
            current.props.providerLabel = this._providerLabel();
          }
          return;
        }
        modals.open('wallet-changed', {
          oldAddress: this._serverAddress(),
          newAddress: pubkeyB58,
          providerLabel: this._providerLabel(),
          dismissible: false
        });
      } catch (e) {
        console.warn('[wallet-watcher] switch modal failed:', e);
      }
    },

    continueSwitch: function(pubkeyB58) {
      pubkeyB58 = pubkeyB58 || this.pendingAddress;
      if (!pubkeyB58) return Promise.resolve();
      return this._reauth(pubkeyB58);
    },

    _reauth: function(pubkeyB58, attempt) {
      attempt = attempt || 1;
      // Every open tab receives Phantom's accountChanged, but the server
      // session has a SINGLE nonce slot (delete-before-verify, OPSEC-018) —
      // concurrent re-auths from multiple tabs overwrite each other's nonce,
      // so the prompt the user actually signs verifies against a dead nonce
      // and 401s. Only the VISIBLE tab re-auths; hidden tabs catch up via
      // the layout's visibilitychange session_state rehydrate on refocus.
      if (document.visibilityState !== 'visible') return Promise.resolve();
      if (this._reauthing) return Promise.resolve(); // one prompt at a time in this tab
      var provider = this._preferredProvider();
      if (!provider) return Promise.reject(new Error('Your wallet is not available in this browser.'));
      this._reauthing = true;
      var self = this;
      return fetch('/auth/solana/nonce')
        .then(function(r) { return r.json(); })
        .then(function(data) {
          var nonce = data.nonce;
          var domain = window.location.host;
          var message = domain + ' wants you to sign in with your Solana account:\n' + pubkeyB58 + '\n\nSign in to Turf Monster\n\nNonce: ' + nonce;
          var encoded = new TextEncoder().encode(message);
          return provider.signMessage(encoded, 'utf8').then(function(signed) {
            var signatureB58 = encodeBase58(signed.signature);
            var csrf = document.querySelector('meta[name="csrf-token"]')?.content || '';
            return fetch('/auth/solana/verify', {
              method: 'POST',
              headers: { 'Content-Type': 'application/json', 'X-CSRF-Token': csrf },
              // Re-auth re-proves the same wallet, so it refreshes the brand
              // stamp (and web3_authenticated_at) exactly like a fresh login.
              body: JSON.stringify({ message: message, signature: signatureB58, pubkey: pubkeyB58, wallet_provider: (provider && provider.name) || undefined })
            });
          });
        })
        .then(function(r) { return r.json(); })
        .then(function(result) {
          self._reauthing = false;
          if (result && result.success) {
            try { if (Alpine.store('modals').isOpen('wallet-changed')) Alpine.store('modals').close(); } catch (e) {}
            window.handleSolanaVerifySuccess(result);
            window.location.reload();
            return;
          }
          // Rejected (stale nonce race / expiry). One automatic retry with a
          // fresh nonce — the in-flight guard above means this tab is alone
          // now, so the second attempt verifies against its own nonce.
          console.warn('[wallet-watcher] re-auth rejected (attempt ' + attempt + '):', result && result.error);
          if (attempt < 2) { return self._reauth(pubkeyB58, attempt + 1); }
          var verifyError = new Error((result && result.error) || (self._providerLabel() + ' could not verify this wallet.'));
          verifyError.walletSwitchFinal = true;
          throw verifyError;
        })
        .catch(function(err) {
          self._reauthing = false;
          if (err && err.walletSwitchFinal) throw err;
          // 4001 = the user dismissed the signature prompt. Keep the blocking
          // handoff open and make the same CTA retryable.
          if (err && err.code === 4001) {
            var cancelled = new Error('Signature request canceled. Your current session is unchanged.');
            cancelled.walletSwitchFinal = true;
            throw cancelled;
          }
          console.warn('[wallet-watcher] re-auth failed:', err);
          if (attempt < 2) { return self._reauth(pubkeyB58, attempt + 1); }
          var finalError = new Error((err && err.message) || 'Could not start a session with this wallet.');
          finalError.walletSwitchFinal = true;
          throw finalError;
        });
    }
  });

  return true;
}

// Register wallet store — Alpine is available by module execution time
if (!registerWalletStore()) {
  document.addEventListener('alpine:init', function() { registerWalletStore(); });
}
