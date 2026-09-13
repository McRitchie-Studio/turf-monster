require "test_helper"
require "open3"
require "json"

# [unit] The inline provider's transaction codec, EXECUTED against the shipped
# source and the RESOLVED gem's base58 — not a paraphrase of either.
#
# WHY IT EXISTS. walletOps hands every transport the same base58 wire bytes,
# because base58 is the only shape that survives a redirect. An injected wallet
# signs a Transaction OBJECT. The conversion belongs to the PROVIDER, and until
# it did, this app kept a second hand-rolled call site for the desktop path —
# the duplication /tasks/collapse-inline-entry-call-site removed.
#
# THE ONE ASSERTION THAT MUST NEVER GO SOFT is the serialize options.
# Every transaction reaching this codec today is CO-SIGNED: prepare_entry builds
# it with the admin signer slot deliberately EMPTY and the server fills it.
# `requireAllSignatures: false` is what lets a partially-signed transaction
# serialize at all, and `verifySignatures: false` stops web3.js rejecting the
# very gap the server is about to close. A bare serialize() throws AFTER the user
# has approved — signed bytes nothing can post, and nothing to retry from — and a
# serialize that quietly dropped one flag would broadcast a transaction missing a
# required signature. Neither failure is visible in a source read, which is why
# the options are captured and compared here rather than grepped.
class WalletInlineTxCodecJsTest < ActiveSupport::TestCase
  SOURCE = Rails.root.join("app/javascript/wallet_provider.js")

  # The REAL base58, from the gem bundler actually resolved. A stub would let
  # this file certify a round trip that the shipped encoder does not perform.
  def gem_wallet_transport
    File.join(Gem.loaded_specs.fetch("solana-studio").full_gem_path,
              "app/assets/javascripts/solana_studio/wallet_transport.js")
  end

  # `body` runs after both files are loaded and must assign to `out`.
  def run_codec(body)
    script = <<~JS
      global.window = global;
      Object.defineProperty(globalThis, "navigator", {
        value: { userAgent: "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) Chrome/128", maxTouchPoints: 0 },
        writable: true, configurable: true
      });

      // solanaWeb3 STUBBED AT ITS TWO TOUCH POINTS ONLY. What is under test is
      // which bytes the codec hands the library and which options it asks it
      // for — not web3.js's own deserializer, which has its own suite.
      var handedToFrom = null;
      global.solanaWeb3 = {
        Transaction: {
          from: function (bytes) {
            handedToFrom = Array.from(bytes);
            return { __deserialized: true, bytes: bytes };
          }
        }
      };

      // A MINIMAL EVENT TARGET, because node has none on the global object and
      // wallet_provider.js's Wallet Standard handshake is built entirely out of
      // events. Its own dispatches sit inside try/catch, so without this the
      // handshake no-ops SILENTLY and a test of it would pass on nothing.
      var _listeners = {};
      global.addEventListener = function (type, cb) { (_listeners[type] = _listeners[type] || []).push(cb); };
      global.removeEventListener = function () {};
      global.dispatchEvent = function (e) { (_listeners[e.type] || []).forEach(function (cb) { cb(e); }); return true; };
      if (typeof CustomEvent === 'undefined') {
        global.CustomEvent = function (type, init) { this.type = type; this.detail = init && init.detail; };
      }

      #{File.read(gem_wallet_transport)}
      #{File.read(SOURCE)}

      // A signed Transaction, as an injected wallet answers with one: the only
      // thing the codec asks of it is serialize(options).
      var serializeCalls = [];
      function fakeSigned(bytes) {
        return {
          serialize: function (opts) {
            serializeCalls.push(opts === undefined ? "NO-OPTIONS" : opts);
            return new Uint8Array(bytes);
          }
        };
      }

      var out = {};
      try {
        #{body}
        out.ok = true;
      } catch (e) {
        out.ok = false;
        out.message = e.message;
      }
      out.handedToFrom = handedToFrom;
      out.serializeCalls = serializeCalls;
      console.log(JSON.stringify(out));
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, stderr
    JSON.parse(stdout.lines.map(&:strip).reject(&:empty?).last)
  end

  # THE THREE INLINE PROVIDERS. detect() returns whichever is present, and a
  # codec on only some of them is a codec that fails on somebody's wallet: the
  # keypair provider drives e2e, the legacy Phantom singleton drives an older
  # extension build, and the Wallet Standard adapter drives every wallet that
  # registers itself — Phantom included, on current builds.
  test "every inline provider carries both halves of the codec" do
    result = run_codec(<<~JS)
      global.phantom = { solana: { isPhantom: true, connect: function () {} } };
      var ws = { name: 'Solflare', icon: 'data:', accounts: [], features: {
        'standard:connect': { connect: function () {} },
        'solana:signMessage': { signMessage: function () {} },
        'solana:signTransaction': { signTransaction: function () {} }
      } };
      out.providers = {};
      [['detect', window.walletProvider.detect()],
       ['phantom', window.walletProvider.get('phantom')],
       ['keypair', window.walletProvider.get('keypair') || null]].forEach(function (pair) {
        var p = pair[1];
        out.providers[pair[0]] = p
          ? [typeof p.deserializeTransaction, typeof p.serializeTransaction]
          : null;
      });
    JS

    assert result["ok"], result["message"]
    assert_equal %w[function function], result["providers"]["detect"],
                 "detect() is what every entry call site takes, so a provider without the " \
                 "codec stops that entry at hold-to-confirm — walletOps refuses BY NAME"
    assert_equal %w[function function], result["providers"]["phantom"],
                 "the legacy Phantom singleton signs for older extension builds"
    assert_equal %w[function function], result["providers"]["keypair"],
                 "the keypair provider is what every e2e entry signs with — without the " \
                 "codec the browser lane cannot reach the flow it exists to certify"
  end

  test "the Wallet Standard adapter is built with the codec, not patched later" do
    result = run_codec(<<~JS)
      // Drive the app's own handshake rather than reaching for the adapter
      // factory: a codec attached in _wsRegister but not in _makeWsAdapter would
      // pass a direct-factory test and still miss a wallet that arrives late.
      window.dispatchEvent(new CustomEvent('wallet-standard:register-wallet', {
        detail: function (api) {
          api.register({
            name: 'Backpack', icon: 'data:', accounts: [],
            chains: ['solana:mainnet'],
            features: {
              'standard:connect': { connect: function () {} },
              'standard:events': { on: function () {} },
              'solana:signMessage': { signMessage: function () {} },
              'solana:signTransaction': { signTransaction: function () {} }
            }
          });
        }
      }));
      var list = window.walletProvider.available();
      out.count = list.length;
      out.shape = list.length ? [typeof list[0].deserializeTransaction, typeof list[0].serializeTransaction] : null;
    JS

    assert result["ok"], result["message"]
    assert_equal 1, result["count"], "the Wallet Standard handshake did not register the wallet"
    assert_equal %w[function function], result["shape"],
                 "a Wallet Standard wallet — which is how current Phantom, Solflare and " \
                 "Backpack all arrive — reached walletOps without the codec"
  end

  test "serializeTransaction asks for the two flags a co-signed entry needs" do
    result = run_codec(<<~JS)
      global.phantom = { solana: { isPhantom: true } };
      var p = window.walletProvider.detect();
      out.wire = p.serializeTransaction(fakeSigned([1, 2, 3, 4]));
    JS

    assert result["ok"], result["message"]
    assert_equal 1, result["serializeCalls"].length, "serialize was not called exactly once"
    assert_equal({ "requireAllSignatures" => false, "verifySignatures" => false },
                 result["serializeCalls"].first,
                 "the entry is CO-SIGNED: the admin signer slot is deliberately empty when " \
                 "the wallet hands the transaction back, so a bare serialize() — or one " \
                 "missing either flag — throws on the missing signature AFTER the user has " \
                 "approved, with signed bytes nothing can post and nothing to retry from")
  end

  test "the codec round-trips through the resolved gem's base58" do
    result = run_codec(<<~JS)
      global.phantom = { solana: { isPhantom: true } };
      var p = window.walletProvider.detect();
      var bytes = [7, 0, 255, 42, 13];
      // Encode the way the intent's prepare() does, then ask the codec to read
      // it back — the exact hop walletOps performs between the two.
      var wire = window.SolanaStudio.walletTransport.base58.encode(new Uint8Array(bytes));
      out.wire = wire;
      out.deserialized = !!p.deserializeTransaction(wire).__deserialized;
      out.returned = p.serializeTransaction(fakeSigned(bytes));
    JS

    assert result["ok"], result["message"]
    assert result["deserialized"], "deserializeTransaction did not reach solanaWeb3.Transaction.from"
    assert_equal [7, 0, 255, 42, 13], result["handedToFrom"],
                 "the bytes handed to web3.js must be the bytes prepare() encoded — a codec " \
                 "that decoded with the wrong alphabet builds a different transaction and " \
                 "the wallet asks the user to approve it"
    assert_equal result["wire"], result["returned"],
                 "the return leg must answer in the SAME wire format the outbound leg speaks, " \
                 "or complete() is handed a base58 string on one transport and an object on " \
                 "the other and the call site branches again"
  end
end
