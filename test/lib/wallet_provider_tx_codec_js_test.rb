require "test_helper"
require "open3"
require "json"

# [unit] THE INLINE TRANSPORT'S TRANSACTION CODEC, exercised in Node against the
# REAL module and the REAL gem base58.
#
# WHY IT EXISTS AT ALL. SolanaStudio.walletOps hands every transport the same
# thing — base58 wire bytes — because that is the only shape that can be written
# to the wallet journal and survive the page death a phone puts in the middle of
# a signature. An injected wallet signs a solanaWeb3.Transaction OBJECT. One
# prepare() cannot return both, and the gem cannot convert (it takes no web3.js
# dependency), so the conversion is the PROVIDER'S, declared as two methods.
# Without them walletOps refuses every inline run BY NAME, and the three flows
# this test guards would have gone back to a per-call-site fork.
#
# THE SERIALIZE OPTIONS ARE THE CO-SIGN CONTRACT, and they are what the middle
# tests assert EXACTLY rather than loosely. Every transaction leaving these
# methods is PARTIALLY signed on purpose — the admin slot is empty and the
# server fills it — so a plain .serialize() asserts every required signature is
# present and throws on precisely the transactions this app signs.
class WalletProviderTxCodecJsTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("app/javascript/wallet_provider.js")

  MAC = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 Chrome/128 Safari/537.36".freeze
  IPHONE = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Safari/604.1".freeze

  # The REAL base58, resolved from the bundle: the bytes under test are the bytes
  # a consumer installs.
  def gem_transport_source
    @gem_transport_source ||= begin
      dir = `bundle show solana-studio 2>/dev/null`.strip
      assert !dir.empty? && Dir.exist?(dir), "could not resolve the solana-studio gem"
      File.read(File.join(dir, "app/assets/javascripts/solana_studio/wallet_transport.js"))
    end
  end

  # `body` runs with: PhantomProvider, KeypairProvider, wsAdapter, walletProvider,
  # solanaWeb3 (a recording stub), and B58 (the gem's real codec).
  def run_js(body, ua: MAC, injected: true)
    script = <<~JS
      global.window = global;
      global.addEventListener = function () {};
      global.dispatchEvent = function () {};
      Object.defineProperty(globalThis, "navigator", {
        value: { userAgent: #{ua.to_json}, maxTouchPoints: 0 },
        writable: true, configurable: true
      });
      #{injected ? "global.phantom = { solana: { isPhantom: true, connect() {}, signTransaction(tx) { return Promise.resolve(tx); } } };" : ""}

      // The gem's own base58 — not a re-typed one.
      #{gem_transport_source}
      const B58 = window.SolanaStudio.walletTransport.base58;

      // A RECORDING solanaWeb3 stub. It records what Transaction.from was handed
      // and what serialize() was called WITH, because the options are the part
      // that carries the co-sign contract and a stub that swallowed them would
      // make every mutation of this code survive.
      const calls = { fromBytes: null, serializeOpts: 'NEVER CALLED' };
      global.solanaWeb3 = {
        Transaction: {
          from: function (bytes) {
            calls.fromBytes = Array.from(bytes);
            return {
              __transaction: true,
              serialize: function (opts) {
                calls.serializeOpts = opts === undefined ? 'NO ARGUMENT' : opts;
                // Deliberately DIFFERENT bytes from the input, so a codec that
                // echoed its argument instead of serialising cannot pass.
                return new Uint8Array([9, 9, 9, 4, 2]);
              }
            };
          }
        }
      };

      const src = require('fs').readFileSync(#{SOURCE.to_s.inspect}, 'utf8');
      const expose = new Function(
        'window',
        src + '; return { PhantomProvider: PhantomProvider, KeypairProvider: KeypairProvider, makeWs: _makeWsAdapter, walletProvider: walletProvider };'
      );
      const M = expose(global.window);
      const wsAdapter = M.makeWs({
        name: 'Solflare',
        accounts: [{ address: 'AAA', publicKey: new Uint8Array(32) }],
        features: { 'standard:events': { on() {} } }
      });
      const providers = { phantom: M.PhantomProvider, keypair: M.KeypairProvider, walletStandard: wsAdapter };

      let out;
      try {
        out = (function () { #{body} })();
      } catch (e) {
        out = { error: e.message };
      }
      console.log(JSON.stringify(out));
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, "node failed: #{stderr}"
    JSON.parse(stdout.lines.map(&:strip).reject(&:empty?).last)
  end

  # --- every inline provider carries both halves ---------------------------

  test "all three inline providers expose both codec methods" do
    result = run_js(<<~JS)
      var shape = {};
      Object.keys(providers).forEach(function (k) {
        shape[k] = [typeof providers[k].deserializeTransaction, typeof providers[k].serializeTransaction];
      });
      return shape;
    JS

    # BOTH HALVES, NAMED PER PROVIDER. walletOps refuses the whole run when
    # either is missing, and serializeTransaction is not reached until AFTER the
    # user has approved a signature — discovering it missing there costs a real
    # signing prompt and strands signed bytes nothing can post.
    assert_equal({ "phantom" => %w[function function],
                   "keypair" => %w[function function],
                   "walletStandard" => %w[function function] },
                 result.except("error"),
                 "every inline provider owes walletOps both conversions")
  end

  # --- the outbound half ---------------------------------------------------

  test "deserializeTransaction hands solanaWeb3 the DECODED bytes" do
    result = run_js(<<~JS)
      var wire = new Uint8Array([1, 2, 3, 250, 0, 77]);
      var tx = providers.phantom.deserializeTransaction(B58.encode(wire));
      return { fromBytes: calls.fromBytes, isTransaction: !!(tx && tx.__transaction) };
    JS

    assert_equal [1, 2, 3, 250, 0, 77], result["fromBytes"],
                 "the base58 must be DECODED into the exact wire bytes — an encode here, or a " \
                 "byte-for-char read, reaches the wallet as a transaction nobody built"
    assert_equal true, result["isTransaction"],
                 "the result must be what solanaWeb3.Transaction.from returned; an injected wallet " \
                 "signs an object and throws on a string"
  end

  # --- the return half, and the contract it carries ------------------------

  test "serializeTransaction serializes with the co-sign options, exactly" do
    result = run_js(<<~JS)
      var signed = solanaWeb3.Transaction.from(new Uint8Array([1, 2, 3]));
      var b58 = providers.phantom.serializeTransaction(signed);
      return { opts: calls.serializeOpts, b58: b58 };
    JS

    # THE ONE RIGHT ANSWER, not "does not throw". A .serialize() with no options
    # verifies every signature and raises on a transaction whose admin slot is
    # deliberately empty — which is every transaction this app sends.
    assert_equal({ "requireAllSignatures" => false, "verifySignatures" => false },
                 result["opts"],
                 "the admin slot is EMPTY by design; serializing with signature verification on " \
                 "throws on every co-signed transaction this app produces")
  end

  test "serializeTransaction returns the base58 of the serialized wire" do
    result = run_js(<<~JS)
      var signed = solanaWeb3.Transaction.from(new Uint8Array([1, 2, 3]));
      var b58 = providers.walletStandard.serializeTransaction(signed);
      return { decoded: Array.from(B58.decode(b58)) };
    JS

    # The stub serializes to [9,9,9,4,2] regardless of input, so an implementation
    # that re-encoded its ARGUMENT rather than the serialized wire fails here.
    assert_equal [9, 9, 9, 4, 2], result["decoded"],
                 "walletOps hands complete() this string on every transport — it must be the " \
                 "SERIALIZED wire, base58-encoded, not the object it was given"
  end

  # --- the codec is INLINE-ONLY --------------------------------------------

  test "the provider a phone gets carries no inline codec" do
    # THE CONTROL. On a phone detect() returns a REDIRECT provider, which never
    # sees a Transaction object at all. If the codec were bolted onto the registry
    # rather than onto the inline providers, this would answer "function" and the
    # four tests above would prove far less than they appear to.
    result = run_js(<<~JS, ua: IPHONE, injected: false)
      window.SolanaStudio.redirectProvider = { forWallet: function () { return { transport: 'redirect' }; } };
      var p = window.walletProvider.detect();
      return { transport: p && p.transport, codec: typeof (p && p.deserializeTransaction) };
    JS

    assert_equal "redirect", result["transport"], "precondition: a phone gets the redirect provider"
    assert_equal "undefined", result["codec"],
                 "the codec belongs to the INLINE providers; advertising it on a redirect provider " \
                 "would claim a conversion that transport can never perform"
  end
end
