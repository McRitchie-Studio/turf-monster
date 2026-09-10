require "test_helper"
require "open3"
require "json"

# [unit] THE contest_create AND contest_bundle HANDLERS, driven directly.
#
# WHAT THIS TIER OWNS. The handlers are two halves split at a seam a page death
# runs through: prepare() runs on the document that started the flow, complete()
# may run on studio-engine's callback page, which never saw it. This tier drives
# each half in isolation with fetch stubbed at the HTTP boundary and nothing
# deeper, so the handlers' own logic runs. Whether they COMPOSE across the seam
# is the integration tier's question; whether they are REGISTERED is the
# component tier's.
class ContestCreateIntentJsTest < ActiveSupport::TestCase
  INTENT = Rails.root.join("app/views/shared/_contest_create_intent.html.erb")
  RUNNER = Rails.root.join("app/views/shared/_wallet_op_runner.html.erb")

  def script_body(path)
    src = File.read(path)
    src[(src.index("<script>") + "<script>".length)...src.rindex("</script>")]
  end

  def gem_transport_source
    @gem_transport_source ||= begin
      dir = `bundle show solana-studio 2>/dev/null`.strip
      assert !dir.empty? && Dir.exist?(dir), "could not resolve the solana-studio gem"
      File.read(File.join(dir, "app/assets/javascripts/solana_studio/wallet_transport.js"))
    end
  end

  # `responses` maps a URL fragment → the JSON body that POST answers with.
  # `body` runs with: posted (every request recorded), shown (every card
  # painted), defined (every intent walletOps.define was handed), and B58.
  #
  # `alpine:` decides whether this world HAS a modal store at all. Both worlds
  # are real: prepare() runs on the page that owns the form, complete() may run
  # on studio-engine's callback document, which never rendered an Alpine store.
  def run_js(body, responses:, authed: true, alpine: true)
    script = <<~JS
      global.window = global;
      global.console = { log: function () {}, warn: function () {}, error: function () {} };
      #{gem_transport_source}
      const B58 = window.SolanaStudio.walletTransport.base58;

      // The registry, recording rather than real: this tier asks what the
      // handlers DO, not whether the gem routes them.
      const defined = {};
      window.SolanaStudio.walletOps = {
        define: function (name, handler) { defined[name] = handler; }
      };

      const shown = [];
      #{alpine ? "window.Alpine = { store: function (n) { return n === 'solanaModal' ? { show: function (t, b) { shown.push([t, b]); } } : null; } };" : ''}

      const posted = [];
      const RESPONSES = #{responses.to_json};
      #{authed ? '' : 'window.__unauthed = true;'}
      window.authedFetch = function (url, opts) {
        posted.push({ url: url, opts: opts, body: opts && opts.body });
        if (window.__unauthed) return Promise.resolve(null);
        var key = Object.keys(RESPONSES).find(function (k) { return url.indexOf(k) !== -1; });
        if (!key) return Promise.reject(new Error('no stubbed response for ' + url));
        return Promise.resolve({ json: function () { return Promise.resolve(RESPONSES[key]); } });
      };

      // A form is a DOM object, and prepare() reads one — deliberately, because
      // prepare ALWAYS runs on the page that owns it. FormData is stubbed so the
      // test can see WHICH form was posted.
      global.FormData = function (form) { this.form = form; };
      global.document = {
        querySelector: function (sel) {
          return sel === '#contest-form' ? { action: 'https://t.test/contests', __form: true } : null;
        }
      };

      #{script_body(RUNNER)}
      #{script_body(INTENT)}

      (async function () {
        let out;
        try {
          out = await (async function () { #{body} })();
        } catch (e) {
          out = { error: e.message };
        }
        console.log = function () {};
        process.stdout.write(JSON.stringify(out));
      })();
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, "node failed: #{stderr}"
    JSON.parse(stdout)
  end

  CREATE_RESPONSES = {
    "/contests" => { success: true, params_token: "TOKEN-1", contest_pda: "PDA-1" },
    "/rebuild" => { success: true, serialized_tx: "AQID" },   # base64 of [1,2,3]
    "/finalize" => { success: true, redirect: "/contests/x", slug: "x" }
  }.freeze

  BUNDLE_RESPONSES = {
    "/generate_bundle" => { success: true, params_token: "BTOKEN", contest_pda: "BPDA", serialized_tx: "AQID" },
    "/finalize_bundle" => { success: true, redirect: "/contests/generator" }
  }.freeze

  # --- both intents declare sign-only --------------------------------------

  test "both intents declare signOnly to the gem, not merely in prose" do
    result = run_js("return { create: defined.contest_create.signOnly, bundle: defined.contest_bundle.signOnly };",
                    responses: CREATE_RESPONSES)

    # walletOps PREFERS signAndSendTransaction where a wallet offers one. Both of
    # these transactions are built with the admin slot EMPTY and cosigned by the
    # server, so a wallet that broadcast one would hand Solana a transaction
    # missing a required signature — and the bytes the server must cosign would
    # never come back. The flag is what makes the transaction's requirement
    # outrank the wallet's capability.
    assert_equal({ "create" => true, "bundle" => true }, result.except("error"),
                 "a co-signed transaction must be SIGNED and handed back, never broadcast by the wallet")
  end

  # --- contest_create, prepare ---------------------------------------------

  test "create prepare posts the whole form, then rebuilds for a fresh blockhash" do
    result = run_js(<<~JS, responses: CREATE_RESPONSES)
      var state = await window.tmPrepareContestCreate({
        csrfToken: 'CSRF', formSelector: '#contest-form',
        rebuildPath: '/rebuild', finalizePath: '/finalize'
      });
      return {
        state: state,
        urls: posted.map(function (p) { return p.url; }),
        postedForm: !!(posted[0].body && posted[0].body.form && posted[0].body.form.__form),
        rebuildBody: posted[1].body
      };
    JS

    assert_nil result["error"]
    # THE FORM ITSELF, banner input included. The image used to ride the FINALIZE
    # post as a File, which cannot be journalled — on a phone it would have
    # vanished with no error. It goes up here instead, on the page that owns it.
    assert_equal true, result["postedForm"],
                 "prepare must post the form it read from the page — that is how the banner travels"
    assert_equal ["https://t.test/contests", "/rebuild"], result["urls"],
                 "the create POST mints the token; the rebuild re-issues the SAME transaction with a " \
                 "fresh blockhash, and it must happen immediately before the wallet sees it"
    assert_equal({ "params_token" => "TOKEN-1" }, JSON.parse(result["rebuildBody"]),
                 "the rebuild is bound to the server-issued token, never to client-held form values")

    # EVERY FIELD A STRING: on the redirect transport this object is written to
    # localStorage verbatim, so a Transaction, a File or a FormData here is a
    # trip that cannot survive its own first hop.
    assert_equal({ "transaction" => "Ldp", "params_token" => "TOKEN-1", "contest_pda" => "PDA-1" },
                 result["state"],
                 "prepare returns base58 wire bytes plus the two ids finalize needs, and nothing else")
  end

  test "create prepare refuses when the form is not on this page" do
    result = run_js(<<~JS, responses: CREATE_RESPONSES)
      try {
        await window.tmPrepareContestCreate({ csrfToken: 'C', formSelector: '#missing' });
        return { threw: false };
      } catch (e) { return { threw: true, message: e.message }; }
    JS

    assert_equal true, result["threw"]
    assert_match(/contest form is not on this page/, result["message"],
                 "a null form dereferenced reads as a wallet fault; the cause is a page without the form")
  end

  test "a 401 during create prepare THROWS rather than resolving empty" do
    result = run_js(<<~JS, responses: CREATE_RESPONSES, authed: false)
      try {
        await window.tmPrepareContestCreate({ csrfToken: 'C', formSelector: '#contest-form', rebuildPath: '/rebuild' });
        return { threw: false };
      } catch (e) { return { threw: true, message: e.message }; }
    JS

    # authedFetch answers FALSY on a 401 having already surfaced the login modal.
    # walletOps is awaiting this promise: a silent undefined would read as a
    # prepared contest and carry an empty transaction to the wallet.
    assert_equal true, result["threw"]
    assert_match(/session expired/i, result["message"])
  end

  # --- contest_create, complete --------------------------------------------

  test "create complete posts the signed wire as base64 with its token" do
    result = run_js(<<~JS, responses: CREATE_RESPONSES)
      var signed = B58.encode(new Uint8Array([7, 7, 7]));
      var data = await window.tmCompleteContestCreate(
        { csrfToken: 'CSRF', finalizePath: '/finalize' },
        { signedTransaction: signed },
        { params_token: 'TOKEN-1', contest_pda: 'PDA-1' }
      );
      return { data: data, body: JSON.parse(posted[0].body), url: posted[0].url };
    JS

    assert_nil result["error"]
    assert_equal "/finalize", result["url"]
    # THE SERVER SPEAKS BASE64 AND THE WALLET SPEAKS BASE58, so the conversion is
    # the handler's. Asserted as the exact bytes rather than "a string".
    assert_equal Base64.strict_encode64([7, 7, 7].pack("C*")), result["body"]["signed_tx"],
                 "the server cosigns these exact bytes — a wrong codec here fails at the cosign guard"
    assert_equal "TOKEN-1", result["body"]["params_token"]
    assert_equal "PDA-1", result["body"]["contest_pda"]
    assert_equal "x", result["data"]["slug"]
  end

  test "create complete REFUSES a wallet that broadcast instead of signing" do
    result = run_js(<<~JS, responses: CREATE_RESPONSES)
      try {
        await window.tmCompleteContestCreate(
          { csrfToken: 'C', finalizePath: '/finalize' },
          { signature: 'SIG-FROM-WALLET', signedTransaction: null },
          { params_token: 'T', contest_pda: 'P' }
        );
        return { threw: false, posts: posted.length };
      } catch (e) { return { threw: true, message: e.message, posts: posted.length }; }
    JS

    # A wallet that broadcast returns a signature and NO transaction. There is
    # nothing to recover: the server never got the bytes it must cosign, so the
    # prize pool did not move and the contest cannot be completed. Refusing
    # loudly beats posting an empty body and reporting success.
    assert_equal true, result["threw"], "a signature with no transaction must not be posted as a success"
    assert_equal 0, result["posts"], "nothing may reach the server once the bytes are known to be missing"
    assert_match(/broadcast this contest instead of signing/, result["message"])
  end

  # --- what the user is looking at while the server works -------------------
  #
  # walletOps.run has NO progress hook between the signing hop and complete(), so
  # a call site cannot paint this leg — the narration can only come from the
  # intent itself. contests/new used to narrate three steps and the generator
  # five; the collapse onto one call left a single static card standing for all
  # of them.

  test "the create finalize leg is narrated rather than left on the signing copy" do
    result = run_js(<<~JS, responses: CREATE_RESPONSES)
      var signed = B58.encode(new Uint8Array([7, 7, 7]));
      await window.tmCompleteContestCreate(
        { csrfToken: 'C', finalizePath: '/finalize' },
        { signedTransaction: signed },
        { params_token: 'T', contest_pda: 'P' }
      );
      return { shown: shown };
    JS

    # #finalize BLOCKS on cosign_and_broadcast_create_contest. Unpainted, the
    # card the admin is staring at still reads "approve the prize-pool USDC
    # transfer in your wallet when it opens" — an approval they have already
    # given — while the server is mid-broadcast.
    assert_equal [["Confirming Onchain", "Cosigning and submitting your contest to Solana..."]],
                 result["shown"],
                 "the wallet is done and the server is not — say so, or the admin reopens the wallet"
  end

  test "a create the wallet broadcast is never narrated as confirming" do
    # THE CONTROL ON THE PAINT'S PLACEMENT. The sign-only refusal posts nothing,
    # so a card painted above it would announce a confirmation that will not
    # happen — and it would be the LAST thing on screen before the throw.
    result = run_js(<<~JS, responses: CREATE_RESPONSES)
      try {
        await window.tmCompleteContestCreate(
          { csrfToken: 'C', finalizePath: '/finalize' },
          { signature: 'SIG', signedTransaction: null },
          { params_token: 'T', contest_pda: 'P' }
        );
      } catch (e) { /* asserted elsewhere */ }
      return { shown: shown };
    JS

    assert_empty result["shown"],
                 "nothing is being cosigned — the refusal is the whole outcome"
  end

  # --- contest_bundle ------------------------------------------------------

  test "bundle prepare sends only the key and returns wire bytes plus its ids" do
    result = run_js(<<~JS, responses: BUNDLE_RESPONSES)
      var state = await window.tmPrepareContestBundle({
        key: 'survivor', csrfToken: 'CSRF', generatePath: '/generate_bundle', finalizePath: '/finalize_bundle'
      });
      return { state: state, body: JSON.parse(posted[0].body), url: posted[0].url };
    JS

    assert_nil result["error"]
    assert_equal "/generate_bundle", result["url"]
    assert_equal({ "key" => "survivor" }, result["body"],
                 "the bundle spec is the SERVER's — the key selects it, and nothing about the contest " \
                 "is client-supplied")
    assert_equal({ "transaction" => "Ldp", "params_token" => "BTOKEN", "contest_pda" => "BPDA" },
                 result["state"])
  end

  test "bundle complete posts the signed wire for the SERVER to broadcast" do
    result = run_js(<<~JS, responses: BUNDLE_RESPONSES)
      var signed = B58.encode(new Uint8Array([4, 5]));
      await window.tmCompleteContestBundle(
        { csrfToken: 'C', finalizePath: '/finalize_bundle' },
        { signedTransaction: signed },
        { params_token: 'BTOKEN', contest_pda: 'BPDA' }
      );
      return { body: JSON.parse(posted[0].body) };
    JS

    # THE BUNDLE USED TO BROADCAST FROM THE BROWSER and post only the resulting
    # SIGNATURE. That half cannot run on the callback document, which loads no
    # solanaWeb3 — so what goes up now is the signed wire itself.
    assert_equal Base64.strict_encode64([4, 5].pack("C*")), result["body"]["signed_tx"],
                 "the server broadcasts now; a body carrying a tx_signature is the old shape"
    assert_nil result["body"]["tx_signature"]
    assert_equal "BTOKEN", result["body"]["params_token"]
  end

  test "bundle complete REFUSES a wallet that broadcast instead of signing" do
    result = run_js(<<~JS, responses: BUNDLE_RESPONSES)
      try {
        await window.tmCompleteContestBundle(
          { csrfToken: 'C', finalizePath: '/finalize_bundle' },
          { signature: 'SIG', signedTransaction: null },
          { params_token: 'B', contest_pda: 'P' }
        );
        return { threw: false, posts: posted.length };
      } catch (e) { return { threw: true, message: e.message, posts: posted.length }; }
    JS

    assert_equal true, result["threw"]
    assert_equal 0, result["posts"]
    assert_match(/broadcast this bundle instead of signing/, result["message"])
  end

  test "the bundle finalize leg is narrated rather than left on the signing copy" do
    result = run_js(<<~JS, responses: BUNDLE_RESPONSES)
      var signed = B58.encode(new Uint8Array([4, 5]));
      await window.tmCompleteContestBundle(
        { csrfToken: 'C', finalizePath: '/finalize_bundle' },
        { signedTransaction: signed },
        { params_token: 'B', contest_pda: 'P' }
      );
      return { shown: shown };
    JS

    # The generator lost the most here: five narrated steps became one static
    # card held for the whole of #finalize_bundle, which cosigns, broadcasts and
    # provisions server-side.
    assert_equal [["Confirming Onchain", "Cosigning and submitting this bundle to Solana..."]],
                 result["shown"]
  end

  test "a document without Alpine still finalizes a contest" do
    # THE ABSENT-CAPABILITY RULE, and this handler runs where it bites: complete()
    # may execute on studio-engine's callback page, which has no Alpine store. An
    # unguarded paint would throw there AFTER the admin approved and AFTER resume()
    # consumed the journal — the original lost-entry incident, at the moment of
    # highest cost. Copy is a courtesy; a contest is not.
    result = run_js(<<~JS, responses: CREATE_RESPONSES, alpine: false)
      var signed = B58.encode(new Uint8Array([7, 7, 7]));
      var data = await window.tmCompleteContestCreate(
        { csrfToken: 'C', finalizePath: '/finalize' },
        { signedTransaction: signed },
        { params_token: 'T', contest_pda: 'P' }
      );
      return { slug: data.slug, posts: posted.length };
    JS

    assert_nil result["error"]
    assert_equal "x", result["slug"], "the finalize POST must still land on a page with no modal store"
    assert_equal 1, result["posts"]
  end
end
