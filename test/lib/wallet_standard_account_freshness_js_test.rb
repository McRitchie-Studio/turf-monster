require "test_helper"
require "json"
require "open3"

# THE WALLET STANDARD ADAPTER MUST NOT CACHE "WHICH ACCOUNT IS CURRENT".
#
# Phantom exposes two interfaces and the app binds whichever is live: the legacy
# injected `window.phantom.solana`, whose `publicKey` is a field the extension
# rewrites, and the Wallet Standard adapter built in _makeWsAdapter, which used
# to answer from a closure variable written in only three places. After the
# 'wallet-provider:registered' swap the adapter IS the watched provider, so that
# closure was the app's whole answer to "who is signing" on a modern Phantom.
#
# WHY A CACHE HERE IS A DEFECT AND NOT AN OPTIMISATION. solana_stores.js's focus
# handler exists precisely because extension events are best-effort: it re-reads
# `provider.publicKey` so a missed accountChanged cannot strand the app on the
# wrong wallet. Fed a cache, that re-read returns the wallet the user just left,
# _handleAccountChanged compares it to the session address, finds them equal and
# returns early — the recovery path re-affirms the stale answer and the
# `connect({onlyIfTrusted:true})` branch that would have found the truth is never
# reached. Measured on a live desk 2026-09-15: adapter.publicKey 6ASf... while
# the wallet's own accounts[0] read 8pM1..., $store.wallet stuck at 'live', and
# no wallet-changed card at all.
#
# The existing e2e coverage could not see it. e2e/wallet_session_switch.spec.js's
# "refocusing recovers when Phantom misses its account-change event" drives the
# LEGACY mock, whose publicKey is live by construction — so the interface that
# was broken was the one no spec exercised.
#
# These assert against the real module executed in node, with `accounts` under
# the test's control, because the property is about WHERE the getter reads.
class WalletStandardAccountFreshnessJsTest < ActiveSupport::TestCase
  # Boots wallet_provider.js in node behind a minimal browser shim, registers a
  # Wallet Standard wallet whose `accounts` the caller drives, and returns
  # whatever the body prints as JSON.
  def run_module(body)
    source = Rails.root.join("app/javascript/wallet_provider.js")
    script = <<~JS
      import { pathToFileURL } from 'node:url';

      // --- minimal browser shim -------------------------------------------
      const listeners = {};
      globalThis.CustomEvent = class {
        constructor(type, init) { this.type = type; this.detail = (init || {}).detail; }
      };
      globalThis.window = {
        addEventListener(type, cb) { (listeners[type] ||= []).push(cb); },
        dispatchEvent(e) { (listeners[e.type] || []).forEach((cb) => cb(e)); return true; }
      };
      globalThis.document = {
        querySelector() { return null; }, getElementById() { return null; },
        addEventListener() {}, createElement() { return {}; }
      };
      globalThis.navigator = { userAgent: 'node', maxTouchPoints: 0 };
      globalThis.localStorage = {
        _d: {}, getItem(k) { return this._d[k] ?? null; },
        setItem(k, v) { this._d[k] = String(v); }, removeItem(k) { delete this._d[k]; }
      };

      // Catch the app-ready handshake BEFORE importing, which is when the
      // module broadcasts it.
      let wsApi = null;
      globalThis.window.addEventListener('wallet-standard:app-ready', (e) => { wsApi = e.detail; });

      await import(pathToFileURL(process.argv[1]).href + '?t=' + Date.now());

      // --- a Wallet Standard wallet whose account list the test drives -----
      const ACCT_A = { address: 'AAAAaaaa1111', publicKey: new Uint8Array([1]), chains: ['solana:mainnet'], features: ['solana:signMessage'] };
      const ACCT_B = { address: 'BBBBbbbb2222', publicKey: new Uint8Array([2]), chains: ['solana:mainnet'], features: ['solana:signMessage'] };
      let accounts = [ACCT_A];
      let changeCb = null;

      const wallet = {
        name: 'Phantom',
        chains: ['solana:mainnet'],
        get accounts() { return accounts; },
        features: {
          'standard:connect': { version: '1.0.0', connect: async () => ({ accounts }) },
          'standard:disconnect': { version: '1.0.0', disconnect: async () => { accounts = []; } },
          'standard:events': { version: '1.0.0', on: (ev, cb) => { if (ev === 'change') changeCb = cb; return () => {}; } },
          'solana:signMessage': { version: '1.0.0', signMessage: async () => [{ signature: new Uint8Array([9]) }] }
        }
      };
      wsApi.register(wallet);
      const adapter = globalThis.window.walletProvider.get('phantom');
      const read = () => (adapter.publicKey ? adapter.publicKey.toBase58() : null);

      #{body}
    JS

    stdout, stderr, status = Open3.capture3(
      "node", "--input-type=module", "--eval", script, source.to_s
    )
    assert status.success?, "node failed:\n#{stderr}"
    JSON.parse(stdout.lines.last)
  end

  # THE DEFECT ITSELF. A switch the wallet never announced — no change event,
  # no reconnect — is exactly the case the focus re-read exists to catch.
  test "publicKey follows the wallet's accounts when no event was delivered" do
    r = run_module(<<~JS)
      await adapter.connect({});
      const afterConnect = read();

      // The wallet moves. Nothing is announced: `changeCb` is never invoked.
      accounts = [ACCT_B];
      const afterSilentSwitch = read();

      console.log(JSON.stringify({ afterConnect, afterSilentSwitch }));
    JS

    assert_equal "AAAAaaaa1111", r["afterConnect"],
      "connect must adopt the account the wallet authorized"
    assert_equal "BBBBbbbb2222", r["afterSilentSwitch"],
      "publicKey must report the wallet's CURRENT account even with no change event — " \
      "a cached answer is what made the focus re-read re-affirm the stale wallet"
  end

  # The cache is not merely refreshed on read — every other consumer of the
  # closure has to move with it, or signMessage would sign with one account
  # while the getter reported another.
  test "the account the getter reports is the account signMessage would use" do
    r = run_module(<<~JS)
      await adapter.connect({});
      accounts = [ACCT_B];
      const reported = read();

      let signedWith = null;
      wallet.features['solana:signMessage'].signMessage = async ({ account }) => {
        signedWith = account.address;
        return [{ signature: new Uint8Array([9]) }];
      };
      await adapter.signMessage(new Uint8Array([1, 2, 3]));

      console.log(JSON.stringify({ reported, signedWith }));
    JS

    assert_equal "BBBBbbbb2222", r["reported"]
    assert_equal r["reported"], r["signedWith"],
      "the getter and the signer must never disagree about which account is current"
  end

  # The empty list is the Wallet Standard's disconnect. Reading live must carry
  # that through as a lost signer rather than resurrecting the last account.
  test "an empty accounts list reads as no signer" do
    r = run_module(<<~JS)
      await adapter.connect({});
      const connected = read();
      accounts = [];
      const afterDisconnect = read();
      console.log(JSON.stringify({ connected, afterDisconnect }));
    JS

    assert_equal "AAAAaaaa1111", r["connected"]
    assert_nil r["afterDisconnect"],
      "an empty accounts array IS the disconnect on this interface; the adapter must not " \
      "keep reporting the account it last saw"
  end

  # THE CONTROL. A wallet that exposes no `accounts` at all must still work off
  # the cached account — otherwise the live read would have turned a missing
  # optional property into a dead adapter.
  test "a wallet without an accounts property still reports its connected account" do
    r = run_module(<<~JS)
      delete wallet.accounts;
      Object.defineProperty(wallet, 'accounts', { value: undefined, configurable: true });
      await adapter.connect({});
      console.log(JSON.stringify({ connected: read() }));
    JS

    assert_equal "AAAAaaaa1111", r["connected"],
      "the live read is an upgrade over the cache, not a replacement for it"
  end
end
