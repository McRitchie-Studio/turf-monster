require "test_helper"
require "open3"
require "json"

# [integration] The whole redirect round trip, across a real page death.
#
# WHAT THIS TIER OWNS AND THE OTHERS CANNOT. The unit test drives the handlers in
# isolation; the component test proves they are registered. Neither shows that
# the pieces COMPOSE — that walletOps, the journal, the redirect provider and
# these two handlers actually hand work to each other across the seam.
#
# And the seam is a page destruction. So this test builds THREE separate JS
# worlds — the document that starts the entry, the callback that lands after
# connect, and the callback that lands after signing — with nothing crossing
# them but localStorage and a URL. That is exactly what crosses them in a
# browser. Anything the handlers kept in a closure would be gone here.
#
# THE GEM IS THE REAL ONE, resolved from the bundle rather than re-typed: the
# bytes under test are the bytes a consumer installs. Fetch is stubbed at the
# HTTP boundary and nowhere deeper, so the handlers' own logic runs.
class ContestEntryRedirectRoundTripTest < ActiveSupport::TestCase
  PARTIAL = Rails.root.join("app/views/contests/_turf_totals_board.html.erb")

  def gem_js_dir
    @gem_js_dir ||= begin
      dir = `bundle show solana-studio 2>/dev/null`.strip
      assert !dir.empty? && Dir.exist?(dir), "could not resolve the solana-studio gem"
      File.join(dir, "app/assets/javascripts/solana_studio")
    end
  end

  def gem_source(*names)
    names.map { |n| File.read(File.join(gem_js_dir, "#{n}.js")) }.join("\n")
  end

  def handlers_source
    src = File.read(PARTIAL)
    start = src.index("window.tmPrepareContestEntry = async function")
    finish = src.index("// selectionBoard")
    src[start...finish]
  end

  def registration_source
    src = File.read(PARTIAL)
    start = src.index("(function () {\n  var S = window.SolanaStudio;")
    finish = src.index("})();", start)
    src[start..(finish + 4)]
  end

  test "an entry survives connect, a page death, signing, and a second page death" do
    script = <<~JS
      // A fake nacl: the crypto itself is driven by solana-studio's own suite
      // with REAL tweetnacl. What is under test here is whether the ENTRY data
      // survives the hops, so the codec is made deterministic rather than real.
      global.nacl = {
        box: {
          keyPair: function () { return { publicKey: new Uint8Array(32).fill(7), secretKey: new Uint8Array(32).fill(9) }; },
          before: function () { return new Uint8Array(32).fill(3); },
          after: function (msg) { return msg; },
          open: { after: function (data) { return data; } }
        },
        randomBytes: function (n) { return new Uint8Array(n).fill(1); }
      };

      // A real in-memory localStorage — the ONLY thing allowed to cross the page
      // deaths below, exactly as in a browser.
      var MEM = {};
      global.localStorage = {
        getItem: function (k) { return k in MEM ? MEM[k] : null; },
        setItem: function (k, v) { MEM[k] = String(v); },
        removeItem: function (k) { delete MEM[k]; },
        get length() { return Object.keys(MEM).length; },
        key: function (i) { return Object.keys(MEM)[i]; }
      };

      var posted = [];
      function freshWorld() {
        // EVERYTHING except localStorage is rebuilt. This is the page death.
        global.window = global;
        global.console = { log: function () {}, warn: function () {}, error: function () {} };
        window.authedFetch = function (url, opts) {
          posted.push({ url: url, body: JSON.parse(opts.body) });
          var payload = url.indexOf('prepare_entry') !== -1
            ? { success: true, serialized_tx: 'AQID', ptx_slug: 'ptx-42', entry_id: 7, entry_pda: 'PDA-9', token_funded: true }
            : { success: true, tx_signature: 'SIG-OK', seeds_earned: 3 };
          return Promise.resolve({ json: function () { return Promise.resolve(payload); } });
        };
        #{gem_source('wallet_transport', 'redirect_provider', 'wallet_journal', 'wallet_ops')}
        #{handlers_source}
        #{registration_source}
      }

      var navigations = [];
      function navigate(u) { navigations.push(u); }

      (async function () {
        // ---- WORLD 1: the contest page ----
        freshWorld();
        var provider = window.SolanaStudio.redirectProvider.forWallet('phantom');
        await window.SolanaStudio.walletOps.run('contest_entry',
          { contestId: 42, csrfToken: 'CSRF', currency: 'usdc' },
          { provider: provider, appUrl: 'https://t.test', redirectLink: 'https://t.test/auth/phantom/callback',
            cluster: 'devnet', navigate: navigate });

        // ---- PAGE DIES. Only localStorage survives. ----
        freshWorld();
        var walletKey = window.SolanaStudio.walletTransport.base58.encode(new Uint8Array(32).fill(5));
        var body = new TextEncoder().encode(JSON.stringify({ public_key: 'USERPK', session: 'SESS' }));
        var connectParams = {
          phantom_encryption_public_key: walletKey,
          nonce: window.SolanaStudio.walletTransport.base58.encode(new Uint8Array(24).fill(1)),
          data: window.SolanaStudio.walletTransport.base58.encode(body)
        };
        var afterConnect = await window.SolanaStudio.walletOps.resume(connectParams,
          { redirectLink: 'https://t.test/auth/phantom/callback', navigate: navigate });

        // ---- PAGE DIES AGAIN. ----
        freshWorld();
        // A VALID base58 string, computed rather than typed. The literal
        // 'B58SIGNED' failed here because base58 excludes I, O, l and 0 — the
        // handler's decode threw on the fixture, not on the code. Worth keeping
        // as a note: a hand-typed base58 constant is very likely invalid.
        var signedB58 = window.SolanaStudio.walletTransport.base58.encode(new Uint8Array([1, 2, 3]));
        var signedBody = new TextEncoder().encode(JSON.stringify({ transaction: signedB58 }));
        var signParams = {
          nonce: window.SolanaStudio.walletTransport.base58.encode(new Uint8Array(24).fill(1)),
          data: window.SolanaStudio.walletTransport.base58.encode(signedBody)
        };
        var done = await window.SolanaStudio.walletOps.resume(signParams, { navigate: navigate });

        process.stdout.write(JSON.stringify({
          navigations: navigations.map(function (u) { return u.split('?')[0]; }),
          afterConnectSuspended: !!(afterConnect && afterConnect.suspended),
          done: !!(done && done.done),
          confirmed: done && done.value && done.value.tx_signature,
          posted: posted
        }));
      })().catch(function (e) { process.stdout.write(JSON.stringify({ error: e.message })); });
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, "node failed: #{stderr}"
    r = JSON.parse(stdout)
    refute r["error"], "round trip errored: #{r['error']}"

    # TWO HOPS: connect, then sign. A cold session cannot sign in one.
    assert_equal ["https://phantom.app/ul/v1/connect", "https://phantom.app/ul/v1/signTransaction"],
                 r["navigations"],
                 "Phantom must SIGN, never signAndSend — this entry is co-signed by the server"
    assert r["afterConnectSuspended"], "connect must advance to the signing hop, not finish"
    assert r["done"], "the second resume must complete the intent"
    assert_equal "SIG-OK", r["confirmed"]

    # THE POINT OF THE WHOLE TEST: the ids minted in WORLD 1 arrived in WORLD 3,
    # through storage and JSON, with every JS object in between destroyed twice.
    prepare, confirm = r["posted"]
    assert_equal "/contests/42/prepare_entry", prepare["url"]
    assert_equal({ "currency" => "usdc" }, prepare["body"])

    assert_equal "/contests/42/confirm_onchain_entry", confirm["url"]
    assert_equal "ptx-42", confirm["body"]["ptx_slug"], "the server-side slug must cross both page deaths"
    assert_equal 7, confirm["body"]["entry_id"]
    assert_equal "PDA-9", confirm["body"]["entry_pda"]
    assert confirm["body"]["signed_tx"].present?, "the signed bytes must reach the server"
  end
end
