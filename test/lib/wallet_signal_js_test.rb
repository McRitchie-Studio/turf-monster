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

      // Flipped by a test to put the page on a cosign surface. The module reads
      // the flag off the DOM, so the harness has to answer the same query the
      // panel's markup would satisfy.
      let onCeremonyPage = false;

      globalThis.document = {
        body: { dataset: { walletAddress: #{SESSION_WALLET.to_json}, walletProvider: 'phantom' } },
      querySelector(selector) {
        if (selector === '[data-wallet-signal-ceremony]') return onCeremonyPage ? {} : null;
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

    // Counts any call at all. This module used to fire one per switch under a
    // comment that was measurably wrong; the counter now exists to keep it gone.
    globalThis.refreshSession = () => {
      refreshes += 1;
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
      out.labelledWallet = Object.keys(mod.WALLET_SIGNAL_LABELS.wallet);
      out.labelledOther = Object.keys(mod.WALLET_SIGNAL_LABELS.other);
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
    # sees as a broken wallet rather than a broken deploy. BOTH label sets are
    # checked: a state worded only for a wallet-authenticated session renders
    # blank for the email admin, which is the population that gets no card.
    assert_equal out["states"].sort, out["labelledWallet"].sort
    assert_equal out["states"].sort, out["labelledOther"].sort
    assert_equal out["states"].sort, out["toned"].sort
  end

  # ── [unit] THE POPULATION THAT SENT THIS BACK ───────────────────────────
  #
  # An admin who signs in by magic link has session[:onchain] false, so
  # SessionContext#mode is web2 — but `require_admin` is `logged_in? && admin?`
  # with no session-mode requirement, and cosign.js has no session-mode gate. So
  # they reach all three treasury surfaces and can co-sign there.
  #
  # The first cut of this file returned `web2` for them before it ever read the
  # browser, so a DECLARED wallet and a stranger's produced the same state, the
  # same words and the same grey dot — on a panel headed "Co-signing wallet",
  # above their own account's address. Enumerated here by name, at Carl's
  # request and for the same reason unknown-vs-none is.
  test "an email-authenticated admin on a ceremony page tells declared from undeclared" do
    out = run_module(<<~JS)
      const SESSION = #{SESSION_WALLET.to_json};
      const DECLARED = #{OTHER_WALLET.to_json};
      const STRANGER = #{THIRD_WALLET.to_json};

      // The account has a wallet linked from an earlier session; THIS session
      // signed in by magic link, so it proved nothing about any wallet.
      const emailAdmin = {
        sessionMode: 'web2', sessionAddress: SESSION, status: 'connected', declared: [DECLARED]
      };

      out.offCeremonyDeclared = mod.walletSignalSnapshot({ ...emailAdmin, observed: DECLARED });
      out.offCeremonyStranger = mod.walletSignalSnapshot({ ...emailAdmin, observed: STRANGER });

      const onCeremony = { ...emailAdmin, ceremony: true };
      out.declared = mod.walletSignalSnapshot({ ...onCeremony, observed: DECLARED });
      out.stranger = mod.walletSignalSnapshot({ ...onCeremony, observed: STRANGER });
      out.ownWallet = mod.walletSignalSnapshot({ ...onCeremony, observed: SESSION });
      out.noProvider = mod.walletSignalSnapshot({ ...onCeremony, status: 'none', observed: null });

      // The same two facts for an admin who DID sign in by wallet signature.
      const walletAdmin = { ...onCeremony, sessionMode: 'web3' };
      out.web3Declared = mod.walletSignalSnapshot({ ...walletAdmin, observed: DECLARED });
      out.web3Stranger = mod.walletSignalSnapshot({ ...walletAdmin, observed: STRANGER });
    JS

    # OFF a ceremony page nothing changes: a managed session's browser wallet
    # signs nothing there, so a wallet it happens to hold is not news.
    assert_equal "web2", out["offCeremonyDeclared"]["state"]
    assert_equal "web2", out["offCeremonyStranger"]["state"]

    # ON one, the two cases must part company. This is acceptance criterion 2.
    assert_equal "expected", out["declared"]["state"]
    assert_equal "changed", out["stranger"]["state"]
    refute_equal out["declared"]["state"], out["stranger"]["state"]

    # Not merely a different state — a different SENTENCE and a different TONE,
    # because the reader sees words and a colour, not a state name.
    refute_equal out["declared"]["label"], out["stranger"]["label"]
    assert_equal "info", out["declared"]["tone"]
    assert_equal "danger", out["stranger"]["tone"],
                 "an undeclared wallet on a treasury page must not read calm"

    # The words say what is true of THIS session rather than borrowing the
    # wallet-session vocabulary, which would assert an identity nobody proved.
    assert_equal "Declared for this ceremony", out["declared"]["label"]
    assert_equal "Not declared for this ceremony", out["stranger"]["label"]
    assert_equal false, out["stranger"]["walletAuthenticated"],
                 "the session row has to be able to disclaim itself"

    # Their own linked wallet is neither a stranger nor a ceremony signer.
    assert_equal "live", out["ownWallet"]["state"]
    assert_equal "This account's wallet", out["ownWallet"]["label"]

    # And "no wallet here" still never collapses into a warning.
    assert_equal "none", out["noProvider"]["state"]

    # A wallet-authenticated admin keeps the vocabulary that was true for them.
    assert_equal "expected", out["web3Declared"]["state"]
    assert_equal "changed", out["web3Stranger"]["state"]
    assert_equal true, out["web3Declared"]["walletAuthenticated"]
    assert_equal "Different wallet connected", out["web3Stranger"]["label"]
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

    # NO SESSION REFRESH, AND THIS ASSERTION USED TO SAY THE OPPOSITE.
    #
    # It asserted one refreshSession() per switch, under a comment claiming a
    # switch staled the balance pill, the tiles, the seeds bar and the token
    # badge. Measured: AccountsController#session_refresh takes no parameters
    # and reads the browser nowhere — it hydrates from
    # `current_user&.solana_connected?` through `fetch_navbar_hydrate`, so every
    # number it returns is keyed to the server's idea of the account and a
    # browser switch cannot move one of them. The call repainted identical
    # values for several blocking Solana RPC reads a time, about three per
    # three-signer ceremony, on the page least able to afford a stall.
    #
    # So the old assertion was pinning a no-op in place. It is inverted rather
    # than deleted: the cost was real, and a guard is what stops it coming back
    # under a fresh wrong reason.
    assert_equal 0, out["refreshes"],
                 "a wallet switch must not fire session_refresh — it returns the same numbers " \
                 "and spends blocking RPC reads to do it"
  end

  # ── [component] the same page, for the admin who signed in by email ─────
  #
  # The derivation is proved for this population in the [unit] tier above. This
  # one drives it through the REAL solana-studio source and the live Alpine
  # store, because the two pieces that carry the fix are a DOM read
  # (data-wallet-signal-ceremony) and a store getter, and neither is exercised
  # by calling the pure function.
  test "an email admin on a ceremony page follows a switch through the real source" do
    out = run_module(<<~JS, browser: true)
      const SESSION = #{SESSION_WALLET.to_json};
      const DECLARED = #{OTHER_WALLET.to_json};
      const STRANGER = #{THIRD_WALLET.to_json};

      // A magic-link admin: the account carries a wallet, the SESSION does not.
      sessionContext.mode = 'web2';
      onCeremonyPage = true;
      Alpine.store('wallet').expectedSwitchAddresses = [DECLARED];
      await settle();

      const read = () => {
        const s = signal();
        return { state: s.state, label: s.label, tone: s.tone, proved: s.walletAuthenticated };
      };

      out.onOwnWallet = read();
      await emit(DECLARED);
      out.onDeclared = read();
      await emit(STRANGER);
      out.onStranger = read();

      // The same browser, the same wallet, on an ordinary page.
      onCeremonyPage = false;
      out.offCeremony = read();

      out.refreshes = refreshes;
    JS

    assert_equal "live", out["onOwnWallet"]["state"]

    assert_equal "expected", out["onDeclared"]["state"]
    assert_equal "Declared for this ceremony", out["onDeclared"]["label"]
    assert_equal "info", out["onDeclared"]["tone"]

    assert_equal "changed", out["onStranger"]["state"]
    assert_equal "Not declared for this ceremony", out["onStranger"]["label"]
    assert_equal "danger", out["onStranger"]["tone"]

    # The store getter, not just the pure function — this is what the session
    # row binds to in order to disclaim itself.
    assert_equal false, out["onStranger"]["proved"]

    # The distinction is what was missing, so assert it as a difference too.
    refute_equal out["onDeclared"]["label"], out["onStranger"]["label"]
    refute_equal out["onDeclared"]["tone"], out["onStranger"]["tone"]

    # And the ceremony flag is what turns it on: the identical browser state on
    # an ordinary page is still not news for a managed session.
    assert_equal "web2", out["offCeremony"]["state"]

    assert_equal 0, out["refreshes"]
  end
end
