require "test_helper"
require "json"
require "open3"

# [component] THE PANEL AND THE HAND-OFF CARD, DRIVEN TOGETHER, in node, from one
# event sequence — app/javascript/wallet_signal.js and app/javascript/solana_stores.js
# both real, plus the real solana-studio identity source underneath.
#
# ── WHY THIS FILE EXISTS ──────────────────────────────────────────────────
#
# wallet_signal.js asserts a relationship to a component it cannot see: the
# `wallet-changed` card that solana_stores.js owns. The two read the SAME list
# ($store.wallet.expectedSwitchAddresses), and the comments in both files lean on
# that to promise they can never disagree about whether a switch was asked for.
#
# Nothing measured it, and on 2026-09-17 they shipped disagreeing. cosign.js clears
# the declared list in its `finally` the instant the last signature is collected,
# while Phantom is still parked on the signer it just used. No wallet moved, so the
# card correctly stayed down — and the panel, re-deriving off the emptied list, went
# red and said no ceremony had asked for this wallet. Two components, one fact, two
# answers, and every test in the suite green: each module was tested alone.
#
# So this is the seam test. It asserts the ONE property that is actually promised:
#
#     the panel reads `changed` exactly when the card is up
#
# THE ONE SEQUENCE THAT PROPERTY DOES NOT COVER, named rather than left for
# someone to find: a declaration made while the card is ALREADY up. The panel
# would read `expected` over an open card — and the UI cannot produce it, because
# that card is `dismissible: false` and blocks the page, so no cosign button can
# be reached behind it. The escape is switching back to the session wallet (which
# closes it) or re-authenticating. If the card ever becomes dismissible, this is
# the sequence to add here, and it will need an answer rather than an assertion.
#
# ── WHAT IS REAL HERE AND WHAT IS NOT ─────────────────────────────────────
#
# Real: both app modules, the gem's identity source, and the wallet store's own
# expectSwitchesTo / clearExpectedSwitches / _notifySwitch. Faked: the browser as
# far down as the provider (the same boundary test/lib/wallet_signal_js_test.rb
# draws), Alpine's store registry, and the modal host — reduced to the four calls
# _notifySwitch makes on it, since what is under test is whether the card is UP,
# not how it renders.
#
# The session is web3 throughout, because that is the only population the card can
# reach at all (solana_stores' init returns early otherwise). For the population
# that gets no card, the panel's words are the whole of the signal and they are
# pinned in wallet_signal_js_test.rb.
class WalletSignalCardAgreementTest < ActiveSupport::TestCase
  SIGNAL = "app/javascript/wallet_signal.js".freeze
  STORES = "app/javascript/solana_stores.js".freeze
  SESSION_WALLET = "SessionWa11etAddress".freeze
  DECLARED_WALLET = "DecLaredWa11etAddress".freeze
  STRANGER_WALLET = "StrangerWa11etAddress".freeze

  def gem_asset
    spec = Gem.loaded_specs["solana-studio"]
    refute_nil spec, "solana-studio is not in this bundle; the signal has no identity source"
    path = File.join(spec.gem_dir, "app/assets/javascripts/solana_studio/wallet_identity.js")
    assert File.exist?(path), "solana-studio #{spec.version} ships no wallet_identity.js"
    path
  end

  # The page, down to the provider. ONE provider object with a LIST of listeners
  # per event, which is the detail that makes this test possible: the gem and the
  # wallet store both subscribe to the same real Phantom, and a harness that kept
  # a single callback would silently let one of them win.
  def harness
    <<~JS
      const stores = {};
      const listeners = { document: {}, window: {} };
      const handlers = {};
      let providerAddress = #{SESSION_WALLET.to_json};

      globalThis.window = globalThis;
      const sessionContext = { mode: 'web3', walletBrand: 'phantom' };

      globalThis.document = {
        visibilityState: 'visible',
        body: { dataset: { walletAddress: #{SESSION_WALLET.to_json}, walletProvider: 'phantom' } },
        // Every cosign surface renders the panel, so this page is a ceremony page.
        querySelector(selector) {
          if (selector === '[data-wallet-signal-ceremony]') return {};
          return null;
        },
        getElementById(id) {
          if (id !== 'session-context') return null;
          return { get textContent() { return JSON.stringify(sessionContext); } };
        },
        addEventListener(event, cb) { (listeners.document[event] = listeners.document[event] || []).push(cb); },
        removeEventListener() {}
      };
      globalThis.addEventListener = (event, cb) => {
        (listeners.window[event] = listeners.window[event] || []).push(cb);
      };
      globalThis.removeEventListener = () => {};

      globalThis.Alpine = {
        store(name, value) {
          if (arguments.length === 2) stores[name] = value;
          return stores[name];
        }
      };

      // THE MODAL HOST, at the four calls _notifySwitch makes on it. `open` is
      // recorded rather than rendered: the question is whether the card is UP.
      const cards = [];
      let openCard = null;
      Alpine.store('modals', {
        isOpen(id) { return !!openCard && openCard.id === id; },
        current() { return openCard; },
        open(id, props) {
          openCard = { id: id, props: props };
          cards.push({ event: 'open', id: id, newAddress: props && props.newAddress });
        },
        close() {
          if (openCard) cards.push({ event: 'close', id: openCard.id });
          openCard = null;
        }
      });

      // Phantom's legacy injected shape, with one listener LIST per event.
      const provider = {
        name: 'phantom',
        isPhantom: true,
        get publicKey() {
          return providerAddress ? { toBase58: () => providerAddress } : null;
        },
        on(event, cb) { (handlers[event] = handlers[event] || []).push(cb); },
        removeListener(event, cb) {
          handlers[event] = (handlers[event] || []).filter((fn) => fn !== cb);
        },
        connect() { return Promise.resolve({ publicKey: provider.publicKey }); },
        disconnect() { return Promise.resolve(); }
      };
      globalThis.solana = provider;
      globalThis.phantom = { solana: provider };

      // turf's registry, at the two methods _preferredProvider asks for.
      globalThis.walletProvider = {
        get(name) { return name === 'phantom' ? provider : null; },
        detect() { return provider; }
      };

      globalThis.StudioSession = {
        registerIdentitySource(source) {
          source.start(() => {});
          return { unregister() {} };
        }
      };
      globalThis.refreshSession = () => Promise.resolve({});

      const settle = () => new Promise((resolve) => setTimeout(resolve, 20));
      const walletStore = () => Alpine.store('wallet');
      const signal = () => Alpine.store('walletSignal');

      // ONE event, both subscribers, exactly as a real accountChanged arrives.
      const emit = async (address) => {
        providerAddress = address;
        (handlers.accountChanged || []).slice().forEach((cb) => cb(provider.publicKey));
        await settle();
      };

      // The agreement, sampled. `cardUp` is the card's own answer, not a copy of
      // the panel's inputs.
      const sample = (label) => ({
        at: label,
        state: signal().state,
        tone: signal().tone,
        cardUp: Alpine.store('modals').isOpen('wallet-changed')
      });
    JS
  end

  def run_pair(body)
    script = <<~JS
      import { readFileSync } from 'node:fs';
      import { pathToFileURL } from 'node:url';
      const out = {};
      #{harness}

      // Plain IIFEs taking `window`, evaluated rather than imported — how a
      // sprockets tag delivers the gem, and how the importmap module behaves once
      // Alpine is already on the page.
      new Function('window', readFileSync(process.argv[2], 'utf8')).call(globalThis, globalThis);
      new Function('window', readFileSync(process.argv[3], 'utf8')).call(globalThis, globalThis);

      // ALPINE CALLS init() ON A STORE IT REGISTERS; this shim is a registry and
      // does not, so the one call the real page makes for us is made here.
      walletStore().init();
      await settle();

      // The real page's discovery loop re-probes for a late provider for four
      // seconds. Nothing arrives late here, and in node those pending timers
      // hold the process open long after the assertions are done.
      clearTimeout(walletStore()._discoveryTimer);

      const mod = await import(pathToFileURL(process.argv[1]).href + '?t=' + Date.now());
      await settle();
      #{body}
      console.log(JSON.stringify(out));
    JS

    args = ["node", "--input-type=module", "--eval", script,
            Rails.root.join(SIGNAL).to_s, gem_asset, Rails.root.join(STORES).to_s]
    stdout, stderr, status = Open3.capture3(*args)
    assert status.success?, "node failed: #{stderr}"
    JSON.parse(stdout.lines.last)
  end

  test "the panel reads changed exactly when the hand-off card is up" do
    out = run_pair(<<~JS)
      const SESSION = #{SESSION_WALLET.to_json};
      const DECLARED = #{DECLARED_WALLET.to_json};
      const STRANGER = #{STRANGER_WALLET.to_json};
      const walk = [];

      walk.push(sample('the session wallet, nothing running'));

      // A ceremony declares the signer it is about to ask for, through the store's
      // own method — the same call cosign.js makes.
      walletStore().expectSwitchesTo([DECLARED]);
      await emit(DECLARED);
      walk.push(sample('a declared switch, mid-ceremony'));

      // THE `finally`. cosign.js clears the suppression the instant collect()
      // returns so it cannot outlive the flow. NO wallet event: the operator has
      // not touched Phantom, and the card therefore cannot move.
      walletStore().clearExpectedSwitches();
      await settle();
      walk.push(sample('the ceremony is over, the wallet has not moved'));

      // A wallet nobody ever declared. This one IS a switch.
      await emit(STRANGER);
      walk.push(sample('an undeclared switch after the ceremony'));

      // Back to the wallet the ceremony declared — but the flow is over, so the
      // suppression is gone and this is an ordinary switch.
      await emit(DECLARED);
      walk.push(sample('back to the declared wallet, flow over'));

      // Switching back to the session's own wallet is the escape from the card.
      await emit(SESSION);
      walk.push(sample('back to the session wallet'));

      out.walk = walk;
      out.cards = cards;
    JS

    walk = out["walk"]

    # THE INVARIANT, on every step, before any per-step expectation: the panel's
    # warning and the card's presence are one fact with two renderings.
    walk.each do |step|
      assert_equal (step["state"] == "changed"), step["cardUp"],
                   "at #{step["at"]}: panel=#{step["state"]} card_up=#{step["cardUp"]} — " \
                   "the panel and the hand-off card disagree about whether this switch was asked for"
    end

    # And the walk itself, so a green run cannot mean "nothing ever happened".
    assert_equal ["live", "expected", "expected", "changed", "changed", "live"],
                 walk.map { |s| s["state"] }

    calm = walk[2]
    assert_equal "expected", calm["state"],
                 "clearing the declared list is not a wallet event — this is the shipped defect"
    assert_equal false, calm["cardUp"]
    refute_equal "danger", calm["tone"]

    # The card genuinely moved during the walk, or the invariant above holds
    # vacuously over a card that was never up.
    events = out["cards"].map { |c| c["event"] }
    assert_includes events, "open", "the card never opened; the agreement would be vacuous"
    assert_includes events, "close", "the card never closed; the escape path is untested"
    assert_equal 1, events.count("open"),
                 "the card latches: a second undeclared switch updates the open card, never reopens it"
  end
end
