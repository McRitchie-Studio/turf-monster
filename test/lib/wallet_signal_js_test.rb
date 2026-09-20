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

  # ── [unit] THE DECLARATION A CEREMONY LEAVES BEHIND ─────────────────────
  #
  # cosign.js clears $store.wallet.expectedSwitchAddresses in its `finally`, which
  # runs the moment collect() returns — while Phantom is still parked on the signer
  # it just used. The list emptying re-derives this signal with NO wallet event, so
  # before rememberDeclaration() existed every SUCCESSFUL ceremony ended with the
  # panel red and a sentence denying the ceremony had happened.
  #
  # The rule is one line of English with one hard edge: the declaration survives
  # only while the wallet it named has not moved. Every case below is a case where
  # getting that edge wrong makes the panel contradict the hand-off card.
  test "a declaration outlives its list only while the wallet has not moved" do
    out = run_module(<<~JS)
      const DECLARED = #{OTHER_WALLET.to_json};
      const STRANGER = #{THIRD_WALLET.to_json};
      const r = (previous, facts) => mod.rememberDeclaration(previous, facts);

      // Recorded while the ceremony is running.
      out.recorded = r("", { observed: DECLARED, declared: [DECLARED] });

      // THE DEFECT'S OWN SEQUENCE: the list empties, the wallet has not moved.
      out.survivesTheClear = r(DECLARED, { observed: DECLARED, declared: [] });
      // ...and it keeps surviving, because the rule is its own fixpoint and an
      // Alpine getter re-evaluates it freely.
      out.stillSurvives = r(out.survivesTheClear, { observed: DECLARED, declared: [] });

      // MOVED. Leaving the declared wallet after the flow ended is a switch the
      // hand-off card raises, so the memory must not make the panel calm for it.
      out.forgottenOnMove = r(DECLARED, { observed: STRANGER, declared: [] });
      // And coming back is the same: the suppression ended with the flow.
      out.noReturnTicket = r(r(DECLARED, { observed: STRANGER, declared: [] }),
                             { observed: DECLARED, declared: [] });

      // A LIVE ASK OUTRANKS THE MEMORY. A second ceremony asking for someone
      // else must not read as calm over the wallet the operator has to leave.
      out.supersededByNewAsk = r(DECLARED, { observed: DECLARED, declared: [STRANGER] });

      // A lock or a disconnect ends it: the wallet re-arrives through
      // _handleAccountChanged, which raises the card on the way in.
      out.forgottenOnDisconnect = r(DECLARED, { observed: null, declared: [] });

      // Nothing is invented from nothing.
      out.nothingFromNothing = r("", { observed: DECLARED, declared: [] });

      // The derivation's use of it, which is the only thing the reader sees.
      const facts = {
        sessionMode: 'web3', sessionAddress: #{SESSION_WALLET.to_json},
        status: 'connected', observed: DECLARED, declared: [], ceremony: true
      };
      out.calm = mod.walletSignalSnapshot({ ...facts, rememberedDeclaration: DECLARED });
      out.alarm = mod.walletSignalSnapshot({ ...facts, rememberedDeclaration: "" });
      out.midCeremony = mod.walletSignalSnapshot({
        ...facts, declared: [DECLARED], rememberedDeclaration: DECLARED
      });
    JS

    assert_equal OTHER_WALLET, out["recorded"]
    assert_equal OTHER_WALLET, out["survivesTheClear"],
                 "the wallet never moved, so nothing happened for the panel to warn about"
    assert_equal OTHER_WALLET, out["stillSurvives"], "the rule must be its own fixpoint"

    assert_equal "", out["forgottenOnMove"]
    assert_equal "", out["noReturnTicket"],
                 "the card's suppression ended with the flow, so a return trip is a real switch"
    assert_equal "", out["supersededByNewAsk"],
                 "a second ceremony's list is the authority while it is running"
    assert_equal "", out["forgottenOnDisconnect"]
    assert_equal "", out["nothingFromNothing"]

    # WHAT THE OPERATOR SEES. Same facts, one remembered address apart.
    assert_equal "expected", out["calm"]["state"]
    assert_equal "info", out["calm"]["tone"]
    assert_equal true, out["calm"]["declarationEnded"],
                 "the panel has to be able to say the ceremony has FINISHED with this wallet"

    assert_equal "changed", out["alarm"]["state"]
    assert_equal "danger", out["alarm"]["tone"]

    # Mid-ceremony the live list is what holds it, so the finished sentence stays
    # down and the mid-ceremony one renders.
    assert_equal "expected", out["midCeremony"]["state"]
    assert_equal false, out["midCeremony"]["declarationEnded"]
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

    # STILL `changed`, AND THE REASON IS THE WALLET MOVED. Step 3 took Phantom to
    # THIRD, so the declaration this page held for OTHER was forgotten the moment
    # a live list failed to name the connected wallet; coming back to OTHER after
    # the list emptied is a switch the hand-off card raises, so the panel has to
    # warn with it. The case where the list empties UNDER an unmoved wallet is a
    # different sequence and a different answer — see the calm-after-a-ceremony
    # test below, which is the defect this assertion was mistaken for.
    assert_equal "changed", trail[4],
                 "leaving a declared wallet and returning after the ceremony ended raises the card, " \
                 "so the panel must warn with it"
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
  # ── [component] completing a ceremony leaves the panel calm ─────────────
  #
  # THE WHOLE DEFECT, DRIVEN THROUGH THE REAL SOURCE AND THE REAL STORE. The
  # [unit] test above proves the rule; this one proves the WIRING, because the
  # thing that broke was never the rule — it was that the declared list is read
  # live and cosign.js empties it with no wallet event behind it. Nothing here
  # emits a switch after the ceremony ends, deliberately: the false alarm arrived
  # without one, so a test that emitted anything would be answering an easier
  # question.
  test "completing a ceremony leaves the panel calm" do
    out = run_module(<<~JS, browser: true)
      const SESSION = #{SESSION_WALLET.to_json};
      const DECLARED = #{OTHER_WALLET.to_json};
      const STRANGER = #{THIRD_WALLET.to_json};

      onCeremonyPage = true;
      await settle();

      const read = () => {
        const s = signal();
        return {
          state: s.state, label: s.label, tone: s.tone,
          declarationEnded: s.declarationEnded, quiet: s.quiet, quietState: s.quietState
        };
      };

      // The ceremony declares the signer and the operator switches to it. Same
      // store field, same assignment cosign.js makes through expectSwitchesTo.
      Alpine.store('wallet').expectedSwitchAddresses = [DECLARED];
      await emit(DECLARED);
      out.midCeremony = read();

      // THE `finally`. collect() has returned, the suppression is cleared so it
      // cannot outlive the flow — and Phantom has not moved.
      Alpine.store('wallet').expectedSwitchAddresses = [];
      await settle();
      out.afterCeremony = read();

      // The same instant, read as the email-authenticated admin who gets no
      // hand-off card at all. The words change; the calm does not.
      sessionContext.mode = 'web2';
      out.afterCeremonyEmailAdmin = read();
      sessionContext.mode = 'web3';

      // AND THE ALARM IS NOT DISARMED. A wallet nobody declared, after the same
      // completed ceremony, still reads as the warning.
      await emit(STRANGER);
      out.thenAStranger = read();

      out.refreshes = refreshes;
    JS

    mid = out["midCeremony"]
    after = out["afterCeremony"]

    assert_equal "expected", mid["state"]
    assert_equal false, mid["declarationEnded"],
                 "while the list still names the wallet, the mid-ceremony sentence is the true one"

    # ACCEPTANCE 1: the panel stays calm. `changed` here is the shipped defect.
    assert_equal "expected", after["state"],
                 "the list emptied with the wallet unmoved, so nothing happened to warn about"
    assert_equal "info", after["tone"]
    refute_equal "danger", after["tone"],
                 "a false red on a treasury surface is how an operator learns to ignore red"

    # ACCEPTANCE 3: the page can say the ceremony HAPPENED rather than deny it.
    assert_equal true, after["declarationEnded"]

    # ACCEPTANCE 2, the card half: no wallet event fired between the two reads, so
    # the hand-off card cannot have moved. A panel that went red here would be
    # contradicting a card that is still down — see the agreement test in
    # test/lib/wallet_signal_card_agreement_test.rb, which drives both modules.
    assert_equal mid["state"], after["state"],
                 "clearing a list is not a wallet event; the card did not move, so the panel must not either"

    email = out["afterCeremonyEmailAdmin"]
    assert_equal "expected", email["state"]
    assert_equal "Declared for this ceremony", email["label"],
                 "the population that gets no card is the one that most needs the words"

    stranger = out["thenAStranger"]
    assert_equal "changed", stranger["state"],
                 "the memory is scoped to the wallet that never moved, not to the page"
    assert_equal "danger", stranger["tone"]

    assert_equal 0, out["refreshes"]
  end

  # ── [component] the panel's fallback lock, measured rather than asserted ─
  #
  # Three places claimed the panel degrades to HIDDEN if data-wallet-signal-ceremony
  # ever fails to read. It did not: the panel gated on `quiet`, which also requires
  # no connected address — and a connected address is the only way "a confident grey
  # dot over two different addresses" can happen. The claim was false for exactly
  # the case it named. Measured here, in the module, rather than by looking for the
  # string "quiet" in an attribute.
  test "the panel's lock fires for the case it was written for" do
    out = run_module(<<~JS, browser: true)
      const STRANGER = #{THIRD_WALLET.to_json};

      // A managed session with a wallet on the account, a stranger's wallet
      // connected in the browser, and the ceremony flag UNREAD.
      sessionContext.mode = 'web2';
      onCeremonyPage = false;
      await emit(STRANGER);

      const s = signal();
      out.flagUnread = { state: s.state, quiet: s.quiet, quietState: s.quietState, address: s.address };

      // THE COST OF THE STATE-ONLY FORM, ON A PAGE THAT READS ITS FLAG: none.
      // Every reachable state with ceremony=true, enumerated.
      const seen = {};
      let quietOnCeremony = null;
      ['unknown', 'none', 'disconnected', 'connected'].forEach((status) => {
        [null, #{SESSION_WALLET.to_json}, STRANGER].forEach((observed) => {
          ['web3', 'web2', 'guest'].forEach((sessionMode) => {
            [[], [STRANGER]].forEach((declared) => {
              ['', #{SESSION_WALLET.to_json}].forEach((sessionAddress) => {
                const snap = mod.walletSignalSnapshot({
                  status, observed, sessionMode, declared, sessionAddress, ceremony: true
                });
                seen[snap.state] = true;
                if (snap.quietState) quietOnCeremony = snap.state;
              });
            });
          });
        });
      });
      out.ceremonyStates = Object.keys(seen).sort();
      out.quietOnCeremony = quietOnCeremony;
    JS

    unread = out["flagUnread"]
    assert_equal "web2", unread["state"]
    refute_nil unread["address"], "the case is a wallet CONNECTED while the flag is unread"

    assert_equal false, unread["quiet"],
                 "this is the measurement: the shipped field cannot fire while a wallet is connected"
    assert_equal true, unread["quietState"],
                 "the panel must degrade to hidden rather than to a grey dot over two addresses"

    assert_nil out["quietOnCeremony"],
               "no quiet-listed state is reachable with the ceremony flag set, which is what makes " \
               "the state-only lock free"
    assert_equal %w[changed disconnected expected live none unknown], out["ceremonyStates"]
  end

  # ── [component] WHICH PROVIDER THE SIGNAL BINDS ─────────────────────────
  #
  # The signal used to watch the INJECTED wallet unconditionally: the registry
  # branch tested `entry.detect()` on what `walletProvider.get()` returns, and
  # `detect` is a method on the REGISTRY rather than on any provider, so the
  # typeof test was always false and every call fell through. A Solflare- or
  # Backpack-brand admin registers through Wallet Standard and injects nothing at
  # window.solana, so that admin was told they have no wallet — the mistake the
  # header of wallet_signal.js calls the most expensive available here.
  #
  # THESE TWO CASES ARE A PAIR AND NEITHER MEANS MUCH ALONE. The first proves the
  # binding happens and that the bound provider's OWN event channel drives the
  # panel. The second proves the binding stops at a provider that has no channel
  # — and the reason that second half exists is that binding a DEAF provider
  # produces the one failure this component cannot have: a page reading CALM over
  # a wallet that has moved. Measured in a real browser on
  # /admin/pending_transactions 2026-09-19: with the deaf provider bound, the
  # injected wallet switched to a stranger and the panel stayed `live`.
  ADAPTER_WALLET = "AdapterWa11etAddress"

  test "the signal binds the brand the session named and follows that provider's own channel" do
    out = run_module(<<~JS, browser: true)
      const SESSION = #{SESSION_WALLET.to_json};
      const ADAPTER = #{ADAPTER_WALLET.to_json};
      const THIRD = #{THIRD_WALLET.to_json};
      await settle();

      // Nothing but the injected wallet exists yet, which is every page that
      // loads before the registry module does.
      out.beforeRegistry = {
        bound: tmWalletSignal.source.current().providerName,
        state: signal().state
      };

      // A Wallet Standard wallet registers under the session's brand. This is
      // _makeWsAdapter's shape where it matters: a LIVE publicKey getter and an
      // `on` that really registers.
      let adapterAddress = ADAPTER;
      let adapterHandler = null;
      const adapter = {
        name: 'Solflare',
        on(event, cb) { if (event === 'accountChanged') adapterHandler = cb; },
        connect() { return Promise.resolve({ publicKey: adapter.publicKey }); },
        get publicKey() { return adapterAddress ? { toBase58: () => adapterAddress } : null; }
      };
      window.walletProvider = { get: (name) => (name === 'solflare' ? adapter : null) };
      sessionContext.walletBrand = 'solflare';
      document.body.dataset.walletProvider = 'solflare';

      // THE REAL ARRIVAL PATH, not a test-only poke: wallet_provider.js fires
      // this on every Wallet Standard registration and the source rescans on it.
      // Without it the gem keeps the binding it already holds, because an
      // accountChanged event folds into the current binding and re-resolves
      // nothing — which is how the first cut of this measurement lied.
      (listeners.window['wallet-provider:registered'] || []).forEach((cb) => cb({}));
      await settle();

      const snap = tmWalletSignal.source.current();
      out.afterRegistry = { bound: snap.providerName, address: snap.address, state: signal().state };

      // The bound provider's OWN channel is what moves the panel now.
      out.adapterChannelRegistered = typeof adapterHandler === 'function';
      adapterAddress = SESSION;
      adapterHandler(adapter.publicKey);
      await settle();
      out.afterAdapterSwitch = signal().state;

      // And the injected wallet no longer speaks for this page. The gem's
      // closure check makes a superseded provider's listener inert.
      providerAddress = THIRD;
      accountChanged(provider.publicKey);
      await settle();
      out.afterInjectedMoved = {
        state: signal().state,
        address: tmWalletSignal.source.current().address
      };
    JS

    assert_equal "phantom", out.dig("beforeRegistry", "bound"),
                 "with no registry the injected wallet is still what the page reads"
    assert_equal "live", out.dig("beforeRegistry", "state")

    assert_equal "Solflare", out.dig("afterRegistry", "bound"),
                 "the registry entry for the session's brand is what the signal must bind — this is " \
                 "the whole change, and a fall-through to the injected wallet reads `phantom` here"
    assert_equal ADAPTER_WALLET, out.dig("afterRegistry", "address"),
                 "bound means READ: the address has to come off the adapter, not off window.solana"
    assert_equal "changed", out.dig("afterRegistry", "state")

    assert_equal true, out["adapterChannelRegistered"],
                 "the gem must have subscribed to the adapter, or the binding is deaf"
    assert_equal "live", out["afterAdapterSwitch"],
                 "a switch announced by the BOUND provider is what the panel now follows"

    assert_equal "live", out.dig("afterInjectedMoved", "state")
    assert_equal SESSION_WALLET, out.dig("afterInjectedMoved", "address"),
                 "one page describes one wallet: the superseded injected provider cannot move it"
  end

  test "a provider that cannot report a switch is never bound, so no wallet moves under a calm panel" do
    out = run_module(<<~JS, browser: true)
      const SESSION = #{SESSION_WALLET.to_json};
      const OTHER = #{OTHER_WALLET.to_json};
      await settle();

      // KeypairProvider's exact shape, from app/javascript/wallet_provider.js:
      // `on()` registers nothing, and publicKey is whatever connect() loaded —
      // it cannot move and it cannot announce.
      const deaf = {
        name: 'keypair',
        on() { /* no-op — the defect, verbatim */ },
        connect() { return Promise.resolve({ publicKey: deaf.publicKey }); },
        get publicKey() { return { toBase58: () => SESSION }; }
      };
      const registry = { get: () => deaf };
      window.walletProvider = registry;
      sessionContext.walletBrand = 'keypair';
      document.body.dataset.walletProvider = 'keypair';
      (listeners.window['wallet-provider:registered'] || []).forEach((cb) => cb({}));
      await settle();

      out.bound = tmWalletSignal.source.current().providerName;
      out.selectorRefused = mod.hostProviderFor(registry, 'keypair', provider) === provider;

      // THE MEASUREMENT. The wallet the browser actually holds moves to a
      // stranger. A page bound to the deaf provider reads SESSION for ever and
      // paints calm; this page has to raise the alarm.
      out.afterSwitch = await emit(OTHER);
      out.deafStillReportsSession = deaf.publicKey.toBase58() === SESSION;

      // THE COUNTERFACTUAL, so the assertion above cannot pass for the wrong
      // reason. Rename that same provider to something not on the list and the
      // selector takes it — which is what the list is for.
      const renamed = { name: 'some-new-wallet', on() {}, get publicKey() { return null; } };
      out.unlistedIsTaken = mod.hostProviderFor({ get: () => renamed }, 'some-new-wallet', provider).name;

      // A registry entry with no `on` AT ALL is refused for the same reason. This
      // is SolanaStudio.redirectProvider's shape, which speaks
      // beginConnect/completeConnect and carries neither `on` nor `publicKey`.
      const channelless = { name: 'phantom', transport: 'redirect', beginConnect() {} };
      out.channellessRefused =
        mod.hostProviderFor({ get: () => channelless }, 'phantom', provider) === provider;

      out.deafList = mod.SIGNAL_DEAF_PROVIDERS;
    JS

    assert_equal "phantom", out["bound"],
                 "the deaf provider must never become the bound one, however the brand names it"
    assert_equal true, out["selectorRefused"]
    assert_equal true, out["deafStillReportsSession"],
                 "the precondition: this provider would have reported the OLD wallet after the switch"
    assert_equal "changed", out["afterSwitch"],
                 "THE PROPERTY. A wallet that moved must read `changed`; a page bound to the deaf " \
                 "provider reads `live` here, which is the silent calm this guard exists to prevent"

    assert_equal "some-new-wallet", out["unlistedIsTaken"],
                 "the refusal has to come from the NAME, or the assertion above proves nothing"
    assert_equal true, out["channellessRefused"]
    assert_equal ["keypair"], out["deafList"]
  end

  # ── [component] the deaf list is ENFORCED, not merely written down ───────
  #
  # SIGNAL_DEAF_PROVIDERS names providers by hand because no reflection can tell
  # a no-op `on()` from a real one — it is a function either way. A hand-kept
  # list rots, and this one rots SILENTLY: the symptom is a calm page.
  #
  # So the list is checked behaviourally instead of trusted. Every provider
  # `walletProvider.get()` can hand back is driven through `on('accountChanged')`
  # against a fixture whose every downstream channel is a spy, and a provider
  # that registered with NONE of them must appear on the list. A provider that
  # forwards to a channel this fixture does not know reads as deaf and fails
  # CLOSED — which is the safe direction, because the remedy is either to list it
  # or to teach the fixture its channel.
  def scan_providers
    signal_src = Rails.root.join(SOURCE)
    provider_src = Rails.root.join("app/javascript/wallet_provider.js")
    script = <<~JS
      import { pathToFileURL } from 'node:url';
      import { readFileSync } from 'node:fs';

      const listeners = {};
      let spyCalls = 0;
      globalThis.CustomEvent = class {
        constructor(type, init) { this.type = type; this.detail = (init || {}).detail; }
      };
      globalThis.window = {
        addEventListener(type, cb) { (listeners[type] ||= []).push(cb); },
        dispatchEvent(e) { (listeners[e.type] || []).forEach((cb) => cb(e)); return true; },
        // EVERY downstream channel a provider could forward to is a spy.
        phantom: { solana: { isPhantom: true, on() { spyCalls += 1; }, publicKey: null } },
        __WALLET_KEYPAIR_SECRET: new Uint8Array(64)
      };
      globalThis.window.solana = globalThis.window.phantom.solana;
      globalThis.document = {
        querySelector() { return null; }, getElementById() { return null; },
        addEventListener() {}, createElement() { return {}; },
        head: { appendChild() {} }
      };
      Object.defineProperty(globalThis, 'navigator', {
        value: { userAgent: 'node', maxTouchPoints: 0 }, configurable: true, writable: true
      });
      globalThis.localStorage = {
        _d: {}, getItem(k) { return this._d[k] ?? null; },
        setItem(k, v) { this._d[k] = String(v); }, removeItem(k) { delete this._d[k]; }
      };

      let wsApi = null;
      globalThis.window.addEventListener('wallet-standard:app-ready', (e) => { wsApi = e.detail; });

      // The registry is a plain script, delivered the way a script tag does.
      new Function('window', readFileSync(process.argv[2], 'utf8')).call(globalThis, globalThis.window);
      const registry = globalThis.window.walletProvider;
      const deafList = (await import(pathToFileURL(process.argv[1]).href)).SIGNAL_DEAF_PROVIDERS;

      const probe = (label, brand) => {
        const p = registry.get(brand);
        if (!p) return { label, brand, resolved: false };
        spyCalls = 0;
        try { p.on('accountChanged', () => {}); } catch (e) { /* a thrower registers nothing */ }
        return { label, brand, resolved: true, name: p.name, registered: spyCalls > 0 };
      };

      const rows = [];
      // The legacy singletons first: get('phantom') prefers a Wallet Standard
      // wallet of the same name, so PhantomProvider is only reachable before one
      // registers.
      rows.push(probe('PhantomProvider', 'phantom'));
      rows.push(probe('KeypairProvider', 'keypair'));

      const changeSpy = { version: '1.0.0', on(ev, cb) { spyCalls += 1; return () => {}; } };
      wsApi.register({
        name: 'Solflare',
        chains: ['solana:mainnet'],
        get accounts() { return []; },
        features: {
          'standard:connect': { version: '1.0.0', connect: async () => ({ accounts: [] }) },
          'standard:events': changeSpy,
          'solana:signMessage': { version: '1.0.0', signMessage: async () => [] }
        }
      });
      rows.push(probe('Wallet Standard adapter', 'solflare'));

      console.log(JSON.stringify({ rows, deafList }));
    JS
    stdout, stderr, status = Open3.capture3(
      "node", "--input-type=module", "--eval", script, signal_src.to_s, provider_src.to_s
    )
    assert status.success?, "node failed:\n#{stderr}"
    JSON.parse(stdout.lines.last)
  end

  test "every provider the registry can hand out either registers a listener or is named deaf" do
    out = scan_providers
    rows = out["rows"]

    assert_equal %w[PhantomProvider KeypairProvider], rows.select { |r| r["resolved"] }.first(2).map { |r| r["label"] },
                 "the scan must actually reach the legacy singletons, or it proves nothing"
    assert_equal 3, rows.count { |r| r["resolved"] },
                 "all three shapes get() can return have to be probed: #{rows.inspect}"

    rows.each do |row|
      next unless row["resolved"]
      next if row["registered"]

      assert_includes out["deafList"], row["name"].to_s.downcase,
                      "#{row['label']} (#{row['name']}) registered with no channel, so a page that " \
                      "bound it could not follow a wallet switch. Either add it to " \
                      "SIGNAL_DEAF_PROVIDERS in app/javascript/wallet_signal.js, or — if it does " \
                      "forward to a channel this fixture does not spy on — teach the fixture that " \
                      "channel. Do not delete this assertion: the symptom it catches is a page that " \
                      "looks calm while the wallet moves."
    end

    keypair = rows.find { |r| r["label"] == "KeypairProvider" }
    assert_equal false, keypair["registered"],
                 "the control: KeypairProvider is the provider this list exists for, and a fixture " \
                 "in which it reads as CHANNELLED cannot fail for anyone else either"
    phantom = rows.find { |r| r["label"] == "PhantomProvider" }
    assert_equal true, phantom["registered"],
                 "the other control: a real channel has to read as one, or every row passes vacuously"
  end
end
