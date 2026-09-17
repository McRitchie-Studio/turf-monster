require "test_helper"
require "json"
require "open3"

# `app/javascript/wallet_signal.js` — the page-level wallet signal, run in node
# against the real module AND the real solana-studio asset it sits on.
#
# ── WHY THIS TIER, AND WHY IT LOADS THE GEM FILE TOO ──────────────────────
#
# The signal is three pieces in a row: solana-studio's walletIdentity source
# reads the wallet, studio-engine's StudioSession compares it to what the page
# was rendered for, and this app decides what that means to a reader. A test
# that stubbed the first two would prove only that this file's own branches
# execute — and every defect this change exists to prevent lives in the SEAM
# between them, not inside a branch.
#
# So the gem's asset is loaded from the installed gem, unmodified and
# unwrapped, exactly as a sprockets script tag delivers it, and the fake stops
# at the wallet provider. That is the same boundary a browser draws. What IS
# stubbed is StudioSession, and only its registration contract: solana-studio
# already proved its source against the real engine store, and re-proving that
# here would test the gem rather than this app's use of it.
#
# ── THE PROPERTY THAT COST THE MOST TO GET RIGHT ──────────────────────────
#
# A cosign ceremony declares the wallets it will walk through, and the watcher
# suppresses its non-dismissible hand-off card for exactly those addresses. The
# engine can also be told a switch is coming — StudioSession.expectChange — but
# its holds are per SOURCE, not per ADDRESS, so a hold taken for a ceremony
# would mark a switch to ANY wallet expected, including one nobody declared.
#
# This app therefore takes no such hold, and this file pins the consequence:
# DURING a declared ceremony, a switch to an undeclared wallet still reads
# `changed`. Delete the address check and that assertion is the one that goes
# red.
class WalletSignalJsTest < ActiveSupport::TestCase
  SOURCE = "app/javascript/wallet_signal.js".freeze
  SESSION_WALLET = "SessionWa11etAddress".freeze
  OTHER_WALLET = "OtherWa11etAddress".freeze
  THIRD_WALLET = "ThirdWa11etAddress".freeze

  # The page's browser, as far down as the wallet provider. Everything below
  # this line is a fake; everything above it is the real thing.
  #
  # THE PAGE IS BUILT BEFORE THE MODULE LOADS, deliberately. wallet_signal.js
  # installs itself on import, exactly as it does on a real page, so a harness
  # that set the session address afterwards would be testing a module that had
  # already decided it was looking at a signed-out browser. That is not a
  # convenience: the first cut of this file did it the other way and the source
  # settled on `disconnected` before the first assertion ran.
  def harness
    <<~JS
      const listeners = { window: {}, document: {} };
      const stores = {};
      let refreshes = 0;
      let registeredName = null;
      let accountChanged = null;
      let providerAddress = #{SESSION_WALLET.to_json};

      globalThis.window = globalThis;

      const sessionContext = { mode: 'web3', walletBrand: 'phantom' };

      globalThis.document = {
        body: { dataset: { walletAddress: #{SESSION_WALLET.to_json}, walletProvider: 'phantom' } },
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

    // Alpine's store, as much of it as this file touches: a registry that keeps
    // getters live. The signal's whole reactive design is getters reading other
    // stores, so a shim that snapshotted values would certify nothing.
    globalThis.Alpine = {
      store(name, value) {
        if (arguments.length === 2) stores[name] = value;
        return stores[name];
      }
    };
    // The wallet watcher's store, reduced to the one field this file reads.
    Alpine.store('wallet', { expectedSwitchAddresses: [] });

    // Phantom's legacy injected shape.
    const provider = {
      name: 'phantom',
      get publicKey() {
        return providerAddress ? { toBase58: () => providerAddress } : null;
      },
      on(event, cb) { if (event === 'accountChanged') accountChanged = cb; },
      removeListener() {},
      connect() { return Promise.resolve({ publicKey: provider.publicKey }); },
      disconnect() { return Promise.resolve(); }
    };
    globalThis.solana = provider;

    // studio-engine's store, at its registration contract only.
    globalThis.StudioSession = {
      registerIdentitySource(source) {
        registeredName = source.name;
        source.start(() => {});
        return { unregister() {} };
      }
    };

    // Records WHAT each refresh was fired for, not only how many. A count alone
    // cannot tell a refresh on a real switch from a spurious one at page load,
    // and the page-load case is the one that would double every visit's
    // session_refresh without ever going red.
    const refreshedFor = [];
    globalThis.refreshSession = () => {
      refreshes += 1;
      // The WALLET's own truth at this instant, not the store's — the store is
      // written by publish(), which runs after the refresh is fired.
      refreshedFor.push(providerAddress);
      return Promise.resolve({});
    };

    const settle = () => new Promise((resolve) => setTimeout(resolve, 20));
    const signal = () => Alpine.store('walletSignal');
    const emit = async (address) => {
      providerAddress = address;
      accountChanged(provider.publicKey);
      await settle();
      return signal().state;
    };
    JS
  end

  def gem_asset
    spec = Gem.loaded_specs["solana-studio"]
    refute_nil spec, "solana-studio is not in this bundle; the signal has no identity source"
    path = File.join(spec.gem_dir, "app/assets/javascripts/solana_studio/wallet_identity.js")
    assert File.exist?(path),
           "solana-studio #{spec.version} ships no wallet_identity.js — the signal cannot be wired to it"
    path
  end

  # Runs `body` as ESM with the module imported as `mod`. With `browser: true`
  # the harness above and the real gem asset are installed first.
  def run_module(body, browser: false)
    preamble =
      if browser
        <<~JS
          const { readFileSync } = await import('node:fs');
          #{harness}
          // A plain IIFE taking `window`, evaluated rather than imported —
          // exactly how a sprockets script tag delivers it.
          new Function('window', readFileSync(process.argv[2], 'utf8')).call(globalThis, globalThis);
        JS
      else
        ""
      end

    script = <<~JS
      import { pathToFileURL } from 'node:url';
      const out = {};
      #{preamble}
      const mod = await import(pathToFileURL(process.argv[1]).href + '?t=' + Date.now());
      #{body}
      console.log(JSON.stringify(out));
    JS

    args = ["node", "--input-type=module", "--eval", script, Rails.root.join(SOURCE).to_s]
    args << gem_asset if browser
    stdout, stderr, status = Open3.capture3(*args)
    assert status.success?, "node failed: #{stderr}"
    JSON.parse(stdout.lines.last)
  end

  # ── [unit] the derivation ───────────────────────────────────────────────

  test "the derivation keeps every population apart, including the two that must never collapse" do
    out = run_module(<<~JS)
      const d = (o) => mod.deriveWalletSignal(o);
      const SESSION = #{SESSION_WALLET.to_json};
      const OTHER = #{OTHER_WALLET.to_json};

      // Nobody signed in. A first-class state, whatever the browser holds.
      out.guest = d({ sessionMode: 'guest', status: 'none' });
      out.guestWithWallet = d({ sessionMode: 'guest', status: 'connected', observed: OTHER });

      // Signed in on a managed/custodial signer: the browser's wallet is not
      // this session's signer, so it can never be a mismatch.
      out.web2 = d({ sessionMode: 'web2', sessionAddress: SESSION, status: 'connected', observed: OTHER });

      // THE TWO THAT MUST NOT COLLAPSE. "Still reading the wallet" is not "you
      // have no wallet", and telling a wallet holder they have none is the most
      // expensive wrong answer available here.
      out.unknown = d({ sessionMode: 'web3', sessionAddress: SESSION, status: 'unknown' });
      out.none = d({ sessionMode: 'web3', sessionAddress: SESSION, status: 'none' });

      // A provider present but holding no account for this site: read-only,
      // not broken, and not somebody else.
      out.disconnected = d({ sessionMode: 'web3', sessionAddress: SESSION, status: 'disconnected' });

      out.live = d({ sessionMode: 'web3', sessionAddress: SESSION, status: 'connected', observed: SESSION });
      out.changed = d({ sessionMode: 'web3', sessionAddress: SESSION, status: 'connected', observed: OTHER });
      out.expected = d({
        sessionMode: 'web3', sessionAddress: SESSION, status: 'connected', observed: OTHER, declared: [OTHER]
      });

      // A web3 session the server never bound an address to is not a wallet
      // session, whatever the mode column says.
      out.web3WithoutAddress = d({ sessionMode: 'web3', status: 'connected', observed: OTHER });

      out.states = mod.WALLET_SIGNAL_STATES;
      out.labelled = Object.keys(mod.WALLET_SIGNAL_LABELS);
      out.toned = Object.keys(mod.WALLET_SIGNAL_TONES);
    JS

    assert_equal "guest", out["guest"]
    assert_equal "guest", out["guestWithWallet"]
    assert_equal "web2", out["web2"]
    assert_equal "unknown", out["unknown"]
    assert_equal "none", out["none"]
    assert_equal "disconnected", out["disconnected"]
    assert_equal "live", out["live"]
    assert_equal "changed", out["changed"]
    assert_equal "expected", out["expected"]
    assert_equal "guest", out["web3WithoutAddress"]

    refute_equal out["unknown"], out["none"],
                 "a page that cannot yet tell must not render as having no wallet"

    # A state added without words or a tone renders a blank chip, which a reader
    # sees as a broken wallet rather than a broken deploy.
    assert_equal out["states"].sort, out["labelled"].sort
    assert_equal out["states"].sort, out["toned"].sort
  end

  test "a declared switch and an undeclared switch differ only by the declared list" do
    out = run_module(<<~JS)
      const facts = {
        sessionMode: 'web3', sessionAddress: #{SESSION_WALLET.to_json},
        status: 'connected', observed: #{OTHER_WALLET.to_json}
      };
      out.undeclared = mod.walletSignalSnapshot({ ...facts, declared: [] });
      out.declared = mod.walletSignalSnapshot({ ...facts, declared: [#{OTHER_WALLET.to_json}] });
      // A ceremony that declared some OTHER wallet does not cover this one.
      out.elsewhere = mod.walletSignalSnapshot({ ...facts, declared: [#{THIRD_WALLET.to_json}] });
    JS

    assert_equal "changed", out["undeclared"]["state"]
    assert_equal "danger", out["undeclared"]["tone"]

    assert_equal "expected", out["declared"]["state"]
    assert_equal "info", out["declared"]["tone"],
                 "a declared ceremony switch is the flow working; painting it red teaches the operator to ignore red"

    assert_equal "changed", out["elsewhere"]["state"],
                 "the card's suppression is scoped to the exact addresses declared, and so is the signal"
  end

  # ── [component] the indicator, driven through a real identity source ────

  test "the indicator follows an undeclared switch, and keeps following it mid-ceremony" do
    out = run_module(<<~JS, browser: true)
      const SESSION = #{SESSION_WALLET.to_json};
      const OTHER = #{OTHER_WALLET.to_json};
      const THIRD = #{THIRD_WALLET.to_json};
      const trail = [];

      // The module installed itself on import. Calling install() again must be
      // a no-op: registering a second source under the same name throws in the
      // engine, and a Turbo host re-runs page scripts.
      out.installIsIdempotent = mod.install() === window.tmWalletSignal;
      await settle();

      trail.push(signal().state);                         // 0 live
      trail.push(await emit(OTHER));                      // 1 an undeclared switch

      // The ceremony declares the wallet it is about to ask for. This is the
      // same call cosign.js makes, on the same store.
      Alpine.store('wallet').expectedSwitchAddresses = [OTHER];
      trail.push(await emit(OTHER));                      // 2 declared

      // STILL MID-CEREMONY, and this wallet is not on the declared list.
      trail.push(await emit(THIRD));                      // 3 undeclared during a ceremony

      Alpine.store('wallet').expectedSwitchAddresses = [];
      trail.push(await emit(OTHER));                      // 4 the ceremony is over

      trail.push(await emit(null));                       // 5 disconnect
      trail.push(await emit(SESSION));                    // 6 back

      out.trail = trail;
      out.refreshes = refreshes;
      out.refreshedFor = refreshedFor;
      out.registeredName = registeredName;
      out.labelWhenChanged = mod.WALLET_SIGNAL_LABELS.changed;
    JS

    trail = out["trail"]

    assert_equal "wallet", out["registeredName"],
                 "the browser source name must match the key studio_session_identities binds under"
    assert out["installIsIdempotent"],
           "a second install must return the first; the engine throws on a duplicate source name"

    assert_equal "live", trail[0], "the browser holding the session wallet reads live"
    assert_equal "changed", trail[1], "an undeclared switch moves the indicator"
    assert_equal "expected", trail[2], "a switch the page declared reads differently"

    # THE ASSERTION A SOURCE-SCOPED HOLD WOULD HAVE TURNED GREEN AND EMPTY.
    assert_equal "changed", trail[3],
                 "an undeclared switch DURING a declared ceremony must still raise the indicator"

    assert_equal "changed", trail[4], "clearing the ceremony re-arms the wallet it had declared"
    assert_equal "disconnected", trail[5], "a disconnect is not a switch to someone else"
    assert_equal "live", trail[6], "switching back resolves"

    # THE CALL ON A SWITCH — the applicational half that had no trigger.
    # refreshSession() already ran on every page load; a switch made with the
    # page open left every wallet-derived value on screen stale.
    assert_equal [OTHER_WALLET, THIRD_WALLET, OTHER_WALLET, nil, SESSION_WALLET], out["refreshedFor"],
                 "one refresh per wallet the browser moves to, and none for the page's own first read"
  end
end
