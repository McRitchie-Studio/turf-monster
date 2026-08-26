require "test_helper"
require "json"
require "open3"

# The wallet watcher is browser JavaScript, but its account-change boundary is
# small enough to exercise without a browser. This harness loads the real
# module in Node, captures the provider callback, and proves a transient empty
# Phantom account cannot turn into a Rails logout navigation.
class WalletAccountChangeJsTest < ActiveSupport::TestCase
  test "a transient empty account preserves the session and the next account opens a blocking handoff" do
    source = Rails.root.join("app/javascript/solana_stores.js")
    script = <<~'JS'
      import { pathToFileURL } from 'node:url';

      const stores = {};
      const opens = [];
      const windowListeners = {};
      let closes = 0;
      let accountChanged;
      let visibilityState = 'visible';
      let providerAddress = 'old-wallet';
      let preferredProviderAvailable = false;
      let onCalls = 0;
      let disconnected;
      let disconnectCalls = 0;

      globalThis.document = {
        get visibilityState() { return visibilityState; },
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
        close() { closes += 1; opens.pop(); }
      };

      // ALPINE WRAPS EVERY STORE IN A REACTIVE PROXY, and reading an
      // object-valued property back hands you a PROXY OF the value rather than
      // the value. Modelling that here is the whole point of this stub.
      //
      // Without it, `store._provider === provider` is TRUE in Node and FALSE in
      // Chrome — so this harness certified a watcher whose live `accountChanged`
      // guard could never pass, and the feature shipped to a browser where the
      // ONLY thing that ever opened the handoff was the focus reconcile. A stub
      // that is easier than the real thing does not test the real thing.
      //
      // Memoised per target, exactly like @vue/reactivity: two reads of the same
      // property must return the SAME proxy (or the store could not compare
      // against itself either), while proxy === raw stays false.
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
        get publicKey() { return { toBase58: () => providerAddress }; },
        connect() {
          return Promise.resolve({ publicKey: { toBase58: () => providerAddress } });
        },
        on(event, callback) {
          // CAPTURE EVERY EVENT, not just the one this file happened to need
          // first. The old stub dropped anything that was not 'accountChanged'
          // on the floor, so a `disconnect` subscription was untestable here:
          // the assertion passed whether or not the module subscribed. Same
          // failure shape the e2e phantom mock had — a stub quieter than the
          // real provider certifies silence as success.
          if (event === 'accountChanged') { onCalls += 1; accountChanged = callback; }
          if (event === 'disconnect') { disconnectCalls += 1; disconnected = callback; }
        }
      };

      // Phantom can expose its legacy injected object before its Wallet
      // Standard adapter finishes registering. The session remembers which
      // brand authenticated, so the watcher must upgrade to that provider
      // instead of remaining bound to the first detected interface.
      const detectedProvider = {
        name: 'solflare',
        get publicKey() { return { toBase58: () => 'old-wallet' }; },
        connect() {
          return Promise.resolve({ publicKey: { toBase58: () => 'old-wallet' } });
        },
        on() {}
      };

      globalThis.window = {
        Alpine,
        location: { href: '/contests/world-cup' },
        walletProvider: {
          detect: () => detectedProvider,
          get: (name) => name === 'phantom' && preferredProviderAvailable ? provider : null
        },
        addEventListener(event, callback) { windowListeners[event] = callback; }
      };

      await import(pathToFileURL(process.argv[1]).href + '?test=' + Date.now());
      const wallet = Alpine.store('wallet');
      wallet.init();
      preferredProviderAvailable = true;
      await new Promise((resolve) => setTimeout(resolve, 250));

      if (!accountChanged) throw new Error('preferred Phantom provider was never watched');
      accountChanged(null);
      accountChanged({ toBase58: () => 'new-wallet' });
      const openedHandoff = JSON.parse(JSON.stringify(opens));
      accountChanged({ toBase58: () => 'old-wallet' });

      // Chrome can report the page hidden while its Phantom side panel owns
      // focus. The concrete event still needs to queue the blocking handoff.
      visibilityState = 'hidden';
      accountChanged({ toBase58: () => 'hidden-wallet' });
      const hiddenHandoff = JSON.parse(JSON.stringify(opens));
      visibilityState = 'visible';
      accountChanged({ toBase58: () => 'old-wallet' });

      // Extension events are best-effort. If one is missed, refocusing Turf
      // Monster must silently reconcile the provider's current account.
      providerAddress = 'focus-wallet';
      if (windowListeners.focus) windowListeners.focus();
      await Promise.resolve();
      await Promise.resolve();
      const focusHandoff = JSON.parse(JSON.stringify(opens));

      // Bind-once. The identity check gates BOTH the "same provider" early
      // return and the bind branch, so while it could never pass, every focus
      // and every one of the 40 discovery ticks stacked another dead listener.
      if (windowListeners.focus) {
        windowListeners.focus(); windowListeners.focus(); windowListeners.focus();
      }
      await Promise.resolve();
      const onCallsAfterRepeatedFocus = onCalls;

      // Harness fidelity, asserted rather than assumed: if this is false the
      // stub is not modelling Alpine and every claim in this file is worthless.
      const providerIsProxiedOnTheStore = wallet._provider !== provider;

      // Snapshot before the provider flip below, which deliberately walks the
      // watcher back to the legacy interface and disturbs both.
      const addressAfterFocus = wallet.address;
      const closesAfterFocus = closes;

      // A -> B -> A. Phantom exposes a legacy injected object AND a Wallet
      // Standard adapter, and which one `_preferredProvider` returns can flip
      // (the adapter registers late; the registry falls back to detect() when
      // the named lookup misses). Coming BACK to a provider we already bound
      // must NOT bind it a second time — two live listeners on one object
      // handle every event twice.
      preferredProviderAvailable = false;
      if (windowListeners.focus) windowListeners.focus();
      await Promise.resolve();
      preferredProviderAvailable = true;
      if (windowListeners.focus) windowListeners.focus();
      await Promise.resolve();
      const onCallsAfterProviderFlip = onCalls;
      wallet.watching = false;

      console.log(JSON.stringify({
        href: window.location.href,
        address: addressAfterFocus,
        openedHandoff,
        hiddenHandoff,
        focusHandoff,
        focusListenerRegistered: !!windowListeners.focus,
        onCallsAfterRepeatedFocus,
        onCallsAfterProviderFlip,
        providerIsProxiedOnTheStore,
        liveModals: opens,
        closes: closesAfterFocus
      }));
    JS

    stdout, stderr, status = Open3.capture3(
      "node", "--input-type=module", "--eval", script, source.to_s
    )
    assert status.success?, stderr

    result = JSON.parse(stdout)
    assert_equal "/contests/world-cup", result.fetch("href"),
                 "an empty accountChanged event must not navigate to /logout"
    assert_equal "focus-wallet", result.fetch("address")
    assert result.fetch("providerIsProxiedOnTheStore"),
           "HARNESS FIDELITY: the stub must wrap stores in a Proxy the way Alpine does. " \
           "Without it `store._provider === provider` is true here and false in Chrome, and " \
           "this file certifies a watcher that discards every live event it receives."

    # THE REGRESSION. A LIVE accountChanged — no focus, no reconcile — must open
    # the handoff by itself. Measured in Chrome 2026-08-24: it did not. The event
    # landed at 11:08:01 and the modal waited for a click at 11:08:13, because the
    # listener's identity guard compared a raw provider against its own reactive
    # proxy and could never be true.
    assert_equal 1, result.fetch("openedHandoff").size,
                 "a live accountChanged must open the handoff WITHOUT waiting for the window to " \
                 "regain focus — a user who switches accounts in Phantom's side panel and keeps " \
                 "reading the page would otherwise see nothing at all"

    assert_equal 1, result.fetch("onCallsAfterRepeatedFocus"),
                 "accountChanged must be bound ONCE per provider object; re-binding on every " \
                 "focus and every discovery tick stacks listeners that can never fire"

    assert_equal 1, result.fetch("onCallsAfterProviderFlip"),
                 "a provider the watcher has already bound must not be bound AGAIN when it is " \
                 "re-selected (legacy interface -> Wallet Standard adapter -> back); two live " \
                 "listeners on one object handle every switch twice"

    modal = result.fetch("openedHandoff").first
    assert_equal "wallet-changed", modal.fetch("id")
    assert_equal false, modal.dig("props", "dismissible")
    assert_equal "old-wallet", modal.dig("props", "oldAddress")
    assert_equal "new-wallet", modal.dig("props", "newAddress")
    assert_equal "Phantom", modal.dig("props", "providerLabel")
    assert_equal "hidden-wallet", result.dig("hiddenHandoff", 0, "props", "newAddress"),
                 "a side-panel account event must not disappear while the page is hidden"
    assert result.fetch("focusListenerRegistered"),
           "the watcher must reconcile when Turf Monster regains focus"
    assert_equal "focus-wallet", result.dig("focusHandoff", 0, "props", "newAddress"),
                 "focus reconciliation must recover a missed extension event"
    assert_equal "focus-wallet", result.fetch("address")
    assert_equal 2, result.fetch("closes")
  end
end
