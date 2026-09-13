require "test_helper"
require "open3"
require "json"

# [integration] A CONTEST CREATE surviving a real page death, twice.
#
# WHAT THIS TIER OWNS AND THE OTHERS CANNOT. The unit tests drive the handlers in
# isolation; the component test proves they are registered. Neither shows that
# the pieces COMPOSE — that walletOps, the journal, the redirect provider and
# these handlers hand work to each other across the seam.
#
# And the seam is a page destruction. So this builds THREE separate JS worlds —
# the document holding the contest form, the callback that lands after connect,
# and the callback that lands after signing — with nothing crossing them but
# localStorage and a URL. That is exactly what crosses them in a browser.
#
# THE FORM EXISTS IN WORLD 1 ONLY, deliberately. prepare() reads the DOM (which
# is safe: it always runs on the page that started the flow) and complete() must
# not — worlds 2 and 3 have no document.querySelector at all, so a handler that
# reached for the form there would throw rather than quietly pass.
#
# THE GEM IS THE REAL ONE, resolved from the bundle: the bytes under test are the
# bytes a consumer installs.
class ContestCreateRedirectRoundTripTest < ActiveSupport::TestCase
  INTENT = Rails.root.join("app/views/shared/_contest_create_intent.html.erb")
  RUNNER = Rails.root.join("app/views/shared/_wallet_op_runner.html.erb")

  def script_body(path)
    src = File.read(path)
    src[(src.index("<script>") + "<script>".length)...src.rindex("</script>")]
  end

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

  def round_trip_script(intent:, ctx:, world_one_extra: "")
    <<~JS
      // A fake nacl: the crypto is driven by solana-studio's own suite with REAL
      // tweetnacl. What is under test here is whether the CONTEST data survives
      // the hops, so the codec is made deterministic rather than real.
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
      function freshWorld(withForm) {
        // EVERYTHING except localStorage is rebuilt. This is the page death.
        global.window = global;
        global.console = { log: function () {}, warn: function () {}, error: function () {} };
        global.FormData = function (form) { this.form = form; };
        // WORLDS 2 AND 3 HAVE NO DOM AT ALL. A handler that reached for the form
        // on the callback page throws here instead of passing quietly.
        global.document = withForm
          ? { querySelector: function (s) { return s === '#contest-form' ? { action: '/contests', __form: true } : null; } }
          : undefined;
        window.authedFetch = function (url, opts) {
          posted.push({ url: url, body: (opts && typeof opts.body === 'string') ? JSON.parse(opts.body) : '<form>' });
          var payload =
            url.indexOf('/rebuild') !== -1 ? { success: true, serialized_tx: 'AQID' } :
            url.indexOf('/finalize') !== -1 ? { success: true, redirect: '/contests/made', slug: 'made' } :
            { success: true, params_token: 'TOKEN-9', contest_pda: 'PDA-9', serialized_tx: 'AQID' };
          return Promise.resolve({ json: function () { return Promise.resolve(payload); } });
        };
        #{gem_source('wallet_transport', 'redirect_provider', 'wallet_journal', 'wallet_ops')}
        #{script_body(RUNNER)}
        #{script_body(INTENT)}
      }

      var navigations = [];
      function navigate(u) { navigations.push(u); }

      (async function () {
        // ---- WORLD 1: the page that owns the form ----
        freshWorld(true);
        #{world_one_extra}
        var provider = window.SolanaStudio.redirectProvider.forWallet('phantom');
        await window.SolanaStudio.walletOps.run(#{intent.to_json}, #{ctx.to_json},
          { provider: provider, appUrl: 'https://t.test', redirectLink: 'https://t.test/auth/phantom/callback',
            cluster: 'devnet', expectedAccount: 'USERPK', navigate: navigate });

        // ---- PAGE DIES. Only localStorage survives. ----
        freshWorld(false);
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
        freshWorld(false);
        // A VALID base58 string, computed rather than typed — base58 excludes
        // I, O, l and 0, so a hand-typed constant is very likely invalid.
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
          value: done && done.value,
          posted: posted
        }));
      })().catch(function (e) { process.stdout.write(JSON.stringify({ error: e.message })); });
    JS
  end

  def run_round_trip(**kwargs)
    stdout, stderr, status = Open3.capture3("node", "--eval", round_trip_script(**kwargs))
    assert status.success?, "node failed: #{stderr}"
    JSON.parse(stdout)
  end

  test "a contest create survives connect, a page death, signing, and a second page death" do
    r = run_round_trip(intent: "contest_create",
                       ctx: { csrfToken: "CSRF", formSelector: "#contest-form",
                              rebuildPath: "/rebuild", finalizePath: "/finalize" })
    refute r["error"], "round trip errored: #{r['error']}"

    # TWO HOPS: connect, then sign. A cold session cannot sign in one.
    assert_equal ["https://phantom.app/ul/v1/connect", "https://phantom.app/ul/v1/signTransaction"],
                 r["navigations"],
                 "Phantom must SIGN, never signAndSend — this transaction is co-signed by the server"
    assert r["afterConnectSuspended"], "connect must advance to the signing hop, not finish"
    assert r["done"], "the second resume must complete the intent"
    assert_equal "made", r.dig("value", "slug")

    # THE POINT OF THE WHOLE TEST: the token minted in WORLD 1 arrived in WORLD 3,
    # through localStorage and JSON, with every JS object in between destroyed
    # twice — and it arrived at a document that never rendered the form.
    create, rebuild, finalize = r["posted"]
    assert_equal "/contests", create["url"]
    assert_equal "<form>", create["body"], "the form itself is posted, banner input included"
    assert_equal "/rebuild", rebuild["url"]
    assert_equal "TOKEN-9", rebuild.dig("body", "params_token")
    assert_equal "/finalize", finalize["url"]
    assert_equal "TOKEN-9", finalize.dig("body", "params_token"),
                 "the server-issued token is what binds the signed wire to the contest the operator described"
    assert_equal "PDA-9", finalize.dig("body", "contest_pda")
    assert_equal "AQID", finalize.dig("body", "signed_tx"),
                 "the signed wire goes back as base64: [1,2,3] signed, re-encoded for the server"
  end

  test "a bundle provision survives the same two page deaths" do
    r = run_round_trip(intent: "contest_bundle",
                       ctx: { key: "survivor", csrfToken: "CSRF",
                              generatePath: "/generate_bundle", finalizePath: "/finalize_bundle" })
    refute r["error"], "round trip errored: #{r['error']}"

    assert_equal ["https://phantom.app/ul/v1/connect", "https://phantom.app/ul/v1/signTransaction"],
                 r["navigations"]
    assert r["done"]

    generate, finalize = r["posted"]
    assert_equal({ "key" => "survivor" }, generate["body"])
    assert_equal "AQID", finalize.dig("body", "signed_tx"),
                 "the SERVER broadcasts now — what crosses is the signed wire, not a tx_signature"
    assert_nil finalize.dig("body", "tx_signature")
  end

  test "a wrong wallet is refused on the connect hop, before any signing prompt" do
    # expectedAccount is declared at run() and rides the JOURNAL, because the
    # connect callback is a DIFFERENT DOCUMENT that may never have loaded the
    # script defining this intent. A hook would be unreachable on exactly the hop
    # it exists to guard.
    script = round_trip_script(intent: "contest_create",
                               ctx: { csrfToken: "CSRF", formSelector: "#contest-form",
                                      rebuildPath: "/rebuild", finalizePath: "/finalize" })
                .sub("public_key: 'USERPK'", "public_key: 'SOMEONEELSE'")
    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, "node failed: #{stderr}"
    r = JSON.parse(stdout)

    assert_match(/Wrong wallet/, r["error"].to_s,
                 "a different account connecting must end the trip with a sentence the operator can act on")
    refute_match(/signTransaction/, r["error"].to_s)
  end
end
