require "test_helper"
require "open3"
require "json"

# [integration] This app's wallet provider driven through the RESOLVED gem's
# walletOps — both real files, in one node process, with only the wallet stubbed.
#
# WHAT THIS TIER OWNS AND THE OTHERS CANNOT. The unit test proves the codec
# converts; the component test proves the board declares one call site; neither
# can see whether the two halves FIT. That seam is a contract between two
# repositories — the gem calls provider.deserializeTransaction and reads
# opts.expectedAccount, this app supplies both — and a version bump on either
# side can break it without touching a line of code here.
#
# It runs the gem bundler actually resolved, not a copy, so it is also the
# behavioural half of the floor asserted in engine_pin_contract_test.
class WalletOpsInlineContractJsTest < ActiveSupport::TestCase
  PROVIDER = Rails.root.join("app/javascript/wallet_provider.js")

  def gem_asset(name)
    File.join(Gem.loaded_specs.fetch("solana-studio").full_gem_path,
              "app/assets/javascripts/solana_studio/#{name}")
  end

  # `connected` is the address the stub wallet answers with; `expected` is what
  # the call site declares. Both prepare and complete record that they ran, so a
  # test can assert on the ORDER of the hops rather than only on the outcome.
  def run_entry(connected:, expected: nil, wire: nil)
    expected_js = expected.nil? ? "null" : expected.to_json

    script = <<~JS
      global.window = global;
      Object.defineProperty(globalThis, "navigator", {
        value: { userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/128", maxTouchPoints: 0 },
        writable: true, configurable: true
      });
      var _listeners = {};
      global.addEventListener = function (t, cb) { (_listeners[t] = _listeners[t] || []).push(cb); };
      global.removeEventListener = function () {};
      global.dispatchEvent = function (e) { (_listeners[e.type] || []).forEach(function (cb) { cb(e); }); return true; };
      if (typeof CustomEvent === 'undefined') {
        global.CustomEvent = function (type, init) { this.type = type; this.detail = init && init.detail; };
      }

      var steps = [];
      // web3.js stubbed at the codec's two touch points. A signed Transaction is
      // whatever signTransaction answers with, so the stub wallet returns an
      // object carrying serialize() — the same shape an extension returns.
      global.solanaWeb3 = {
        Transaction: {
          from: function (bytes) {
            steps.push('deserialize');
            return { bytes: bytes, serialize: function () { return bytes; } };
          }
        }
      };

      #{File.read(gem_asset("wallet_transport.js"))}
      #{File.read(gem_asset("wallet_ops.js"))}
      #{File.read(PROVIDER)}

      // THE INJECTED WALLET, stubbed at the two calls walletOps makes of it.
      // Everything else on the path — the codec, the connect-before-prepare
      // ordering, the expected-account guard — is the real thing.
      global.phantom = { solana: {
        isPhantom: true,
        connect: function () {
          steps.push('connect');
          return Promise.resolve({ publicKey: { toString: function () { return #{connected.to_json}; } } });
        },
        signTransaction: function (tx) {
          steps.push('sign');
          return Promise.resolve(tx);
        }
      } };

      var PREPARED = window.SolanaStudio.walletTransport.base58.encode(new Uint8Array(#{(wire || [1, 2, 3]).to_json}));

      window.SolanaStudio.walletOps.define('contest_entry', {
        signOnly: true,
        prepare: function () {
          steps.push('prepare');
          return { transaction: PREPARED, ptx_slug: 'ptx-1' };
        },
        complete: function (ctx, result) {
          steps.push('complete');
          return { signedTransaction: result.signedTransaction, sendStrategy: result.sendStrategy };
        }
      });

      var out = {};
      window.SolanaStudio.walletOps.run('contest_entry', { contestId: 1 }, {
        provider: window.walletProvider.detect(),
        expectedAccount: #{expected_js}
      }).then(function (value) {
        out.ok = true;
        out.value = value;
      }).catch(function (e) {
        out.ok = false;
        out.message = e.message;
        out.wrongAccount = !!e.wrongAccount;
      }).then(function () {
        out.steps = steps;
        out.prepared = PREPARED;
        console.log(JSON.stringify(out));
      });
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, stderr
    JSON.parse(stdout.lines.map(&:strip).reject(&:empty?).last)
  end

  ADDRESS = "6ASf5EcmmEHTgDJ4X4ZT5vT6iHVJBXPg5AN5YoTCpGWt".freeze
  OTHER   = "9xQeWvG816bUx9EPjHmaT23yvVM2ZWbrrpZb9PusVFin".freeze

  test "one call site carries a co-signed entry from wire bytes to wire bytes" do
    result = run_entry(connected: ADDRESS, expected: ADDRESS)

    assert result["ok"], "the entry did not complete: #{result["message"]}"
    assert_equal %w[connect prepare deserialize sign complete], result["steps"],
                 "the inline hops changed shape — this is the ORDER the flow depends on"
    assert_equal result["prepared"], result["value"]["signedTransaction"],
                 "complete() must be handed base58 wire bytes, exactly as it is on the " \
                 "redirect transport. Hand it a signed Transaction object here and the " \
                 "call site has to branch on which transport it is again, which is the " \
                 "duplication one call site exists to remove"
    assert_equal "app-broadcasts", result["value"]["sendStrategy"],
                 "the entry is CO-SIGNED — the server cosigns and broadcasts, so a wallet " \
                 "that sent it would submit a transaction missing a required signature " \
                 "AND leave the server without the bytes it must cosign"
  end

  test "the codec contract is satisfied without walletOps refusing by name" do
    result = run_entry(connected: ADDRESS, expected: ADDRESS)

    refute_match(/has no (de)?serializeTransaction/, result["message"].to_s,
                 "the resolved gem refused this app's provider BY NAME, before it touched " \
                 "the wallet — every desktop entry would stop at hold-to-confirm")
  end

  test "a wrong wallet is refused before a prepared transaction is minted" do
    result = run_entry(connected: OTHER, expected: ADDRESS)

    assert_equal false, result["ok"], "the wrong wallet was allowed to sign an entry"
    assert result["wrongAccount"], "the refusal must be tagged, not just worded"
    assert_match(/Wrong wallet/i, result["message"])

    # THE CLAIM THIS TASK MAKES ABOUT expectedAccount, asserted rather than
    # described. It is UX, not security — Anchor rejects any enter_contest_direct
    # whose signer does not match the entry PDA's owner either way. What it buys
    # is a readable sentence AND, on this transport only, a prepared-transaction
    # row that is never minted for the wrong wallet, because walletOps connects
    # BEFORE it prepares. If prepare ran here, the app just spent a server-side
    # record and a fresh blockhash to learn something connect already knew.
    assert_equal %w[connect], result["steps"],
                 "prepare_entry ran anyway — the wrong-wallet check no longer sits between " \
                 "connect and prepare, so every wrong-wallet attempt strands a real " \
                 "PreparedTransaction row"
  end

  test "an undeclared expected account leaves every existing flow untouched" do
    result = run_entry(connected: OTHER, expected: nil)

    assert result["ok"], "declaring nothing must check nothing: #{result["message"]}"
    assert_equal %w[connect prepare deserialize sign complete], result["steps"]
  end
end
