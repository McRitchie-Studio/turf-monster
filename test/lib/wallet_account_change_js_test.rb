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

      globalThis.Alpine = {
        store(name, value) {
          if (arguments.length === 2) stores[name] = value;
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
          if (event === 'accountChanged') accountChanged = callback;
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
      wallet.watching = false;

      console.log(JSON.stringify({
        href: window.location.href,
        address: wallet.address,
        openedHandoff,
        hiddenHandoff,
        focusHandoff,
        focusListenerRegistered: !!windowListeners.focus,
        liveModals: opens,
        closes
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
    assert_equal 1, result.fetch("openedHandoff").size

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
