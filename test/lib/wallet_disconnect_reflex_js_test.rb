require "test_helper"
require "json"
require "open3"

# DEFECT B — the disconnect signal.
#
# Losing the signer is the one wallet event the app most needs to notice, and
# today it notices nothing. Two independent holes, and BOTH have to close or the
# indicator has nothing to update it:
#
#   1. `_handleAccountChanged` opens `if (!publicKey) return;`. The comment is
#      right that a null must not log the user out — but the code goes from
#      "don't log out" to "do nothing at all".
#   2. Phantom's `disconnect` event is never subscribed to. Measured
#      2026-08-25: `grep -rn "'disconnect'" app/javascript/ app/views/` finds
#      zero listeners repo-wide.
#
# This harness mirrors test/lib/wallet_account_change_js_test.rb, including the
# memoised Proxy — see the long note there. A stub that stores raw objects
# passes against the broken code, so the fidelity check is asserted here too
# rather than assumed.
class WalletDisconnectReflexJsTest < ActiveSupport::TestCase
  test "losing the signer surfaces a degraded state without ending the Rails session" do
    source = Rails.root.join("app/javascript/solana_stores.js")
    script = <<~'JS'
      import { pathToFileURL } from 'node:url';

      const stores = {};
      const opens = [];
      const windowListeners = {};
      let accountChanged;
      let disconnected;
      let providerAddress = 'old-wallet';
      let providerConnected = true;

      globalThis.document = {
        get visibilityState() { return 'visible'; },
        body: { dataset: { walletAddress: 'old-wallet', walletProvider: 'phantom' } },
        getElementById(id) {
          return id === 'session-context'
            ? { textContent: JSON.stringify({ mode: 'web3' }) }
            : null;
        },
        addEventListener() {}
      };

      const modals = {
        isOpen(id) { return opens.some((entry) => entry.id === id); },
        current() { return opens[opens.length - 1] || null; },
        open(id, props) { opens.push({ id, props }); },
        close() { opens.pop(); }
      };

      // Alpine wraps stores in a reactive Proxy; reading an object-valued
      // property back hands you a proxy OF the value. Memoised per target so
      // two reads return the SAME proxy while proxy === raw stays false.
      const _proxies = new WeakMap();
      const reactive = (target) => {
        if (target === null || typeof target !== 'object') return target;
        if (_proxies.has(target)) return _proxies.get(target);
        const proxy = new Proxy(target, {
          get(obj, prop, recv) {
            const value = Reflect.get(obj, prop, recv);
            return (value !== null && typeof value === 'object') ? reactive(value) : value;
          }
        });
        _proxies.set(target, proxy);
        return proxy;
      };

      globalThis.Alpine = {
        store(name, value) {
          if (arguments.length === 2) stores[name] = reactive(value);
          return stores[name];
        }
      };
      Alpine.store('modals', modals);

      const provider = {
        name: 'phantom',
        get publicKey() {
          return providerConnected ? { toBase58: () => providerAddress } : null;
        },
        get isConnected() { return providerConnected; },
        connect() {
          return providerConnected
            ? Promise.resolve({ publicKey: { toBase58: () => providerAddress } })
            : Promise.reject(new Error('not trusted'));
        },
        on(event, callback) {
          if (event === 'accountChanged') accountChanged = callback;
          if (event === 'disconnect') disconnected = callback;
        }
      };

      globalThis.window = {
        Alpine,
        location: { href: '/contests/world-cup' },
        walletProvider: { detect: () => provider, get: () => provider },
        addEventListener(event, callback) { windowListeners[event] = callback; }
      };

      await import(pathToFileURL(process.argv[1]).href + '?test=' + Date.now());
      const wallet = Alpine.store('wallet');
      wallet.init();
      await new Promise((resolve) => setTimeout(resolve, 250));

      // HARNESS FIDELITY — if this is false every claim below is worthless.
      const providerIsProxiedOnTheStore = wallet._provider !== provider;

      // Is the disconnect channel even wired? This is hole 2, and it is a
      // question about the MODULE, not about any later assertion.
      const disconnectSubscribed = typeof disconnected === 'function';

      // Hole 1 — the extension locks, or the user switches to an account that
      // has never approved this site. Phantom's observable is a null.
      providerConnected = false;
      providerAddress = null;
      if (accountChanged) accountChanged(null);
      await new Promise((resolve) => setTimeout(resolve, 20));

      const afterNull = {
        signerAvailable: wallet.signerAvailable,
        signerAddress: wallet.signerAddress,
        state: wallet.state,
        href: window.location.href,
        modals: JSON.parse(JSON.stringify(opens))
      };

      // Hole 2 — the explicit disconnect event.
      //
      // RESTORE A LIVE SIGNER FIRST. Firing `disconnect` while the store is
      // ALREADY degraded from the null above proves nothing: the assertion
      // below would read `signerAvailable === false` either way, and a
      // no-op disconnect handler passes it. Measured — that exact version of
      // this test went green against a handler mutated to `if (false)`.
      // The event has to have something to change.
      providerConnected = true;
      providerAddress = 'old-wallet';
      if (accountChanged) accountChanged({ toBase58: () => 'old-wallet' });
      await new Promise((resolve) => setTimeout(resolve, 20));
      const signerRestored = wallet.signerAvailable;

      providerConnected = false;
      providerAddress = null;
      if (disconnected) disconnected();
      await new Promise((resolve) => setTimeout(resolve, 20));

      const afterDisconnect = {
        signerAvailable: wallet.signerAvailable,
        state: wallet.state
      };

      wallet.watching = false;

      console.log(JSON.stringify({
        providerIsProxiedOnTheStore,
        disconnectSubscribed,
        signerRestored,
        afterNull,
        afterDisconnect
      }));
    JS

    stdout, stderr, status = Open3.capture3(
      "node", "--input-type=module", "--eval", script, source.to_s
    )
    assert status.success?, stderr

    result = JSON.parse(stdout)

    assert result.fetch("providerIsProxiedOnTheStore"),
           "HARNESS FIDELITY: the stub must wrap stores in a Proxy the way Alpine does, or " \
           "this file certifies a watcher that discards every live event it receives."

    # HOLE 2. Nothing in the repo subscribes to `disconnect` today.
    assert result.fetch("disconnectSubscribed"),
           "the watcher must subscribe to Phantom's `disconnect` event — losing the signer is " \
           "the event the user most needs a signal for, and it is currently the only wallet " \
           "event the app never asked to hear"

    # HOLE 1. A null must not log the user out — AND must not be silence.
    assert_equal "/contests/world-cup", result.dig("afterNull", "href"),
                 "a null accountChanged must NOT navigate to a logout; the Rails session is " \
                 "still valid and only the browser signer went away"

    assert_equal false, result.dig("afterNull", "signerAvailable"),
                 "a null accountChanged must SURFACE the loss of the signer. Today " \
                 "_handleAccountChanged returns early on !publicKey, so the store keeps " \
                 "reporting the stale address and the green check stays lit over a wallet " \
                 "that can no longer sign anything"

    assert_nil result.dig("afterNull", "signerAddress"),
               "the signer's address must be CLEARED when the signer goes away. Leaving the " \
               "last-known pubkey behind is the same disease as the green check itself — a " \
               "stale fact presented as a live one, which anything downstream (the reconnect " \
               "card, a later refresh) will read as a wallet that is still there"

    assert_equal "degraded", result.dig("afterNull", "state"),
                 "losing the signer degrades to read-only rather than breaking: balances stay " \
                 "readable by address, and authentication only becomes an issue at a web3 task"

    assert_empty result.dig("afterNull", "modals"),
                 "a lost signer is not a wallet SWITCH — it must not open the blocking " \
                 "wallet-changed handoff, which asks the user to sign with an account that " \
                 "is not there"

    # The disconnect assertion is only meaningful from a LIVE state — see the
    # note in the harness. If this is false the two below are vacuous.
    assert result.fetch("signerRestored"),
           "TEST FIDELITY: the signer must be live again before `disconnect` fires, or the " \
           "assertions below pass against a store that was already degraded"

    assert_equal false, result.dig("afterDisconnect", "signerAvailable"),
                 "an explicit disconnect event must reach the same degraded state as a null " \
                 "accountChanged; they are two observables of one fact"
    assert_equal "degraded", result.dig("afterDisconnect", "state")
  end
end
