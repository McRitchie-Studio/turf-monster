// Solana Alpine stores — module supplement
// The solanaModal store, solanaConnectAndVerify/postMagicLink, and
// fireSuccessConfetti are registered inline in application.html.erb (before
// Alpine) to avoid module timing issues.
// This module registers the wallet watcher store (fine to load late).

function registerWalletStore() {
  if (typeof Alpine === 'undefined') return false;
  if (Alpine.store('wallet')) return true;

  // --- Wallet Watcher Store ---
  // Detects wallet switches and hands the user into an explicit re-auth flow.
  Alpine.store('wallet', {
    address: null,
    watching: false,
    pendingAddress: null,

    init: function() {
      // Only WEB3 (live Phantom-signature) sessions may engage Phantom. A
      // web2/managed/guest user has a server-held keypair (or no wallet), so
      // probing Phantom — even silently with onlyIfTrusted — pops the unlock
      // prompt on an installed+previously-trusted extension on EVERY page
      // load. Gate on the canonical session mode (the #session-context JSON,
      // the same source Alpine.store('session') hydrates from) read directly,
      // so this is correct regardless of alpine:init store-registration order.
      if (!this._isWeb3Session()) return;

      var provider = window.walletProvider.detect();
      var serverAddr = this._serverAddress();
      if (!provider || !serverAddr) return;

      var self = this;

      // Silent probe — detect current wallet without popup
      provider.connect({ onlyIfTrusted: true })
        .then(function(resp) {
          self.address = resp.publicKey.toBase58();
          if (self.address !== serverAddr) {
            self._notifySwitch(self.address);
          }
        })
        .catch(function() {}); // Intentional: wallet not yet approved by user — no action needed

      // Listen for wallet switches (Phantom-specific, no-op for keypair)
      provider.on('accountChanged', function(publicKey) {
        if (publicKey) {
          var newAddr = publicKey.toBase58();
          self.address = newAddr;
          if (newAddr !== self._serverAddress()) {
            self._notifySwitch(newAddr);
          }
        } else {
          window.location.href = '/logout';
        }
      });

      this.watching = true;
    },

    _serverAddress: function() { return document.body.dataset.walletAddress || ''; },

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

    _reauthing: false,

    _notifySwitch: function(pubkeyB58) {
      if (document.visibilityState !== 'visible') return;
      if (!pubkeyB58 || pubkeyB58 === this._serverAddress()) return;
      this.pendingAddress = pubkeyB58;
      try {
        var modals = window.Alpine && Alpine.store && Alpine.store('modals');
        if (!modals) return;
        if (modals.isOpen && modals.isOpen('wallet-changed')) return;
        modals.open('wallet-changed', {
          oldAddress: this._serverAddress(),
          newAddress: pubkeyB58
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
      var provider = window.walletProvider.detect();
      if (!provider) return Promise.resolve();
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
          self._fallbackToManualConnect();
        })
        .catch(function(err) {
          self._reauthing = false;
          // 4001 = the user dismissed the signature prompt — respect that,
          // no retry, no fallback (they chose to stay on the old session).
          if (err && err.code === 4001) return;
          console.warn('[wallet-watcher] re-auth failed:', err);
          if (attempt < 2) { return self._reauth(pubkeyB58, attempt + 1); }
          self._fallbackToManualConnect();
        });
    },

    // Silent re-auth failed twice — never strand the user with a navbar that
    // silently still shows the OLD account. Open the Connect Wallet picker so
    // they can complete the switch by hand (the path that always works).
    _fallbackToManualConnect: function() {
      try {
        if (window.Alpine && Alpine.store('modals')) {
          Alpine.store('modals').open('wallet-connect', { linkMode: false, currentUserId: null });
          return;
        }
      } catch (e) { /* fall through */ }
      window.location.href = '/signin';
    }
  });

  return true;
}

// Register wallet store — Alpine is available by module execution time
if (!registerWalletStore()) {
  document.addEventListener('alpine:init', function() { registerWalletStore(); });
}
