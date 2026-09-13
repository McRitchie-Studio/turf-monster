require "test_helper"
require "open3"
require "json"

# [unit] The username_rename intent's two halves, EXECUTED against the real view
# source.
#
# WHAT MAKES THIS FLOW DIFFERENT FROM contest_entry, and therefore what this file
# has to cover that its sibling does not:
#
#   1. IT IS NOT signOnly. A set_username transaction has exactly one signer — the
#      user — so the wallet MAY broadcast it, and on Solflare and Backpack it
#      does. walletOps then answers `wallet-broadcasts` with a signature and no
#      bytes to send. On desktop (runInline ignores signOnly entirely) and on
#      Phantom mobile (its send-side deeplink is deprecated) it answers
#      `app-broadcasts` with bytes and no signature. complete() must handle BOTH,
#      and the two branches share almost nothing, so both are driven here.
#
#   2. SOMETHING ELSE MAY ALREADY BE POSTING THE FINALIZE. On the inline
#      transport studio-engine's leveling modal is still awaiting the hook and
#      posts confirm_username itself; on the callback document it is gone and
#      complete() must post it. The discriminator is the presence of
#      window.tmUsernameRenameCaller, and getting it backwards either confirms a
#      rename twice or never confirms it at all — neither of which any
#      source-text assertion can see.
#
# ASSERTED BY RUNNING THE SHIPPED SOURCE, not a paraphrase of it.
class UsernameRenameIntentJsTest < ActiveSupport::TestCase
  PARTIAL = Rails.root.join("app/views/shared/_username_rename_intent.html.erb")

  # Pull the handler block out of the view verbatim.
  #
  # STARTS BELOW THE ERB TAG ON PURPOSE. The finalize URL is emitted from the
  # route helper (`<%%= confirm_username_account_path %%>`), which node cannot
  # parse — so the extraction begins at the first line after it. That is not a
  # gap in coverage: the URL is read at the CALL SITE, never by these handlers,
  # which take it through ctx.
  def handlers_source
    src = File.read(PARTIAL)
    start = src.index("window.tmUsernameRenameCaller = null;")
    finish = src.index("</script>")
    assert start, "could not find the caller ledger in the partial"
    assert finish && finish > start, "could not bound the handler block"
    slice = src[start...finish]
    assert_not_includes slice, "<%", "the extracted handler block must contain no ERB"
    slice
  end

  # Build a node world and run `script` in it.
  #
  # `authed_fetch:` false is THE CALLBACK DOCUMENT — authedFetch ships in a
  # deferred importmap module, so on the one page complete() actually runs on it
  # is simply not there. `poll:` false is the same fact about pollConfirmation,
  # which lives in that identical module and which the OLD hook called directly.
  def run_js(script, caller_alive: false, authed_fetch: true, poll: true, csrf_meta: "CSRF",
             finalize_body: { "status" => "saved", "username" => "zed" }, finalize_status: 200)
    fetch_js =
      if authed_fetch
        "window.authedFetch = function (u, o) { calls.push(['fetch', u, o]); " \
          "return Promise.resolve({ json: function () { return Promise.resolve(#{finalize_body.to_json}); } }); };"
      elsif finalize_status == 401
        "window.fetch = function (u, o) { calls.push(['fetch', u, o]); " \
          "return Promise.resolve({ status: 401, json: function () { return Promise.resolve({}); } }); };"
      else
        "window.fetch = function (u, o) { calls.push(['fetch', u, o]); " \
          "return Promise.resolve({ status: 200, json: function () { return Promise.resolve(#{finalize_body.to_json}); } }); };"
      end

    poll_js =
      if poll
        "window.pollConfirmation = function (url, sig) { calls.push(['poll', url, sig]); return Promise.resolve({ confirmationStatus: 'confirmed' }); };"
      else
        # No pollConfirmation: the fallback runs, and it reaches for window.fetch
        # against the RPC endpoint. Answer one 'confirmed' immediately so the
        # test does not sit through a real 1.5s interval.
        <<~NOPOLL
          var _realFetch = window.fetch;
          window.fetch = function (u, o) {
            if (String(u).indexOf('rpc.test') !== -1) {
              calls.push(['rpc', u, JSON.parse(o.body).method]);
              return Promise.resolve({ ok: true, json: function () {
                return Promise.resolve({ result: { value: [{ confirmationStatus: 'confirmed', err: null }] } });
              } });
            }
            return _realFetch(u, o);
          };
        NOPOLL
      end

    caller_js =
      caller_alive ? "window.tmUsernameRenameCaller = { onProgress: function (l) { calls.push(['progress', l]); } };" : ""

    full = <<~JS
      global.window = global;
      var calls = [];
      // The document both transports run against: <body data-solana-rpc-url> is
      // in layouts/application, so it is present on the callback page too.
      global.document = {
        body: { dataset: { solanaRpcUrl: 'https://rpc.test' } },
        // csrf_meta: nil is a document served WITHOUT csrf_meta_tags — which the
        // e2e server actually is, because it disables forgery protection.
        querySelector: function (sel) { return #{csrf_meta.nil? ? 'null' : "(sel.indexOf('csrf') !== -1 ? { content: #{csrf_meta.to_json} } : null)"}; }
      };
      #{fetch_js}
      // The gem's codec, stubbed at its PUBLIC surface only — base58 itself has
      // its own suite in solana-studio. What is under test here is whether these
      // handlers convert in the right DIRECTION at each end.
      window.SolanaStudio = { walletTransport: { base58: {
        encode: function (bytes) { return 'B58<' + Array.from(bytes).join(',') + '>'; },
        decode: function (s) { return new Uint8Array(String(s).replace(/^B58</, '').replace(/>$/, '').split(',').map(Number)); }
      } } };
      // web3.js, at the one method complete() reaches. A real Connection is not
      // what is being tested; WHETHER a broadcast happens at all is.
      global.solanaWeb3 = { Connection: function (url, commitment) {
        calls.push(['connection', url, commitment]);
        this.sendRawTransaction = function (bytes, opts) {
          calls.push(['send', Array.from(bytes).join(','), opts]);
          return Promise.resolve('SENT_SIG');
        };
      } };
      console.log = function () {};
      #{handlers_source}
      #{poll_js}
      #{caller_js}
      var RESULT;
      (async function () {
        try { RESULT = { ok: true, value: await (#{script}) }; }
        catch (e) { RESULT = { ok: false, message: e.message }; }
        RESULT.calls = calls;
        process.stdout.write(JSON.stringify(RESULT));
      })();
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", full)
    assert status.success?, "node failed: #{stderr}"
    JSON.parse(stdout)
  end

  # --- prepare -------------------------------------------------------------

  test "prepare returns only values that survive being written to storage" do
    # THE CONTRACT THE REDIRECT TRANSPORT IMPOSES: this return value is
    # serialised to localStorage verbatim. Anything here that is not JSON would
    # arrive on the other side as {} and the rename would fail after the user
    # had already approved it.
    result = run_js("window.tmPrepareUsernameRename({ challenge: 'AQID', token: 'T' })")

    assert result["ok"], result["message"]
    state = result["value"]
    assert_equal JSON.parse(state.to_json), state, "everything prepare returns must round-trip through JSON"
    assert_equal ["transaction"], state.keys
    # base64 "AQID" is bytes 1,2,3 — proving the base64→base58 hop actually ran,
    # in that direction. The server speaks base64; every wallet deeplink
    # protocol speaks base58.
    assert_equal "B58<1,2,3>", state["transaction"]
  end

  test "prepare refuses a challenge the server never sent" do
    # walletOps is awaiting a promise. Returning undefined here would read as a
    # successfully prepared rename and send the user to a wallet with nothing to
    # sign — the same silent-undefined shape the entry intent's 401 test pins.
    result = run_js("window.tmPrepareUsernameRename({ token: 'T' })")

    refute result["ok"], "a missing challenge must reject, not resolve"
    assert_match(/could not save username/i, result["message"])
  end

  test "prepare makes no network call at all" do
    # THE ABSENCE THAT MATTERS. accounts#update_username already minted the
    # challenge and the signed token before the hook was called, so prepare has
    # nothing to mint. That is why this flow needs no outstanding-prepare ledger
    # to retire on a rejected signature, unlike contest_entry — and if a server
    # round trip ever appears here, that reasoning stops holding.
    result = run_js("window.tmPrepareUsernameRename({ challenge: 'AQID', token: 'T' })")

    assert result["ok"], result["message"]
    assert_empty result["calls"], "prepare must not touch the network"
  end

  # --- complete: the two send strategies -----------------------------------

  def complete_call(strategy:, signature: nil, signed: nil, ctx_csrf: "CTX_CSRF")
    payload = { sendStrategy: strategy, signature: signature, signedTransaction: signed }.to_json
    ctx = { token: "TOK", finalizeUrl: "/account/confirm_username", csrfToken: ctx_csrf }.to_json
    "window.tmCompleteUsernameRename(#{ctx}, #{payload}, { transaction: 'B58<1,2,3>' })"
  end

  test "app-broadcasts: the app sends the bytes and waits for the chain" do
    # Every desktop rename and every Phantom mobile rename lands here.
    result = run_js(complete_call(strategy: "app-broadcasts", signed: "B58<9,8,7>"))

    assert result["ok"], result["message"]
    assert_equal "SENT_SIG", result["value"]["proof"]

    kinds = result["calls"].map(&:first)
    assert_includes kinds, "send", "app-broadcasts means the APP owns the broadcast"
    assert_includes kinds, "poll", "a proof is only opaque-proof once it is confirmed"

    send_call = result["calls"].find { |c| c.first == "send" }
    assert_equal "9,8,7", send_call[1], "the base58 the wallet returned must be decoded before sending"
    assert_equal "https://rpc.test", result["calls"].find { |c| c.first == "connection" }[1]
  end

  test "wallet-broadcasts: the app sends nothing and trusts the wallet's signature" do
    # Solflare and Backpack take signAndSendTransaction on the redirect
    # transport. Re-sending here would be a duplicate broadcast for a signature
    # already in hand.
    result = run_js(complete_call(strategy: "wallet-broadcasts", signature: "WALLET_SIG"))

    assert result["ok"], result["message"]
    assert_equal "WALLET_SIG", result["value"]["proof"]

    kinds = result["calls"].map(&:first)
    refute_includes kinds, "send", "the wallet already broadcast this — sending again is a duplicate"
    refute_includes kinds, "connection", "no Connection is needed when nothing is being sent"
    assert_includes kinds, "poll", "the proof still has to be confirmed before confirm_username verifies it"
  end

  test "wallet-broadcasts with no signature is refused rather than posted empty" do
    result = run_js(complete_call(strategy: "wallet-broadcasts"))

    refute result["ok"]
    assert_match(/did not return a signature/i, result["message"])
  end

  test "app-broadcasts with no signed transaction is refused rather than sent empty" do
    result = run_js(complete_call(strategy: "app-broadcasts"))

    refute result["ok"]
    assert_match(/did not return a signed transaction/i, result["message"])
  end

  test "the branch is on the declared strategy, not on which field is populated" do
    # THE BUG THIS PINS. A redirect signTransaction response can carry BOTH a
    # signature and the bytes. Sniffing for `result.signature` would read that as
    # a completed broadcast and skip the send, leaving a signed transaction that
    # never reaches the chain — and confirm_username would then fail TxVerifier
    # on a signature for a transaction nobody submitted.
    result = run_js(complete_call(strategy: "app-broadcasts", signature: "DECOY", signed: "B58<4,5,6>"))

    assert result["ok"], result["message"]
    assert_equal "SENT_SIG", result["value"]["proof"], "app-broadcasts must send, even with a signature present"
    assert_includes result["calls"].map(&:first), "send"
  end

  # --- complete: who posts the finalize ------------------------------------

  test "the callback document posts the finalize itself and names where to land" do
    # The engine's leveling modal died with the page that started the rename.
    # If complete() does not post confirm_username here, nothing does: the
    # rename is on-chain and never mirrored to the database.
    result = run_js(complete_call(strategy: "app-broadcasts", signed: "B58<1,2,3>"),
                    caller_alive: false)

    assert result["ok"], result["message"]
    post = result["calls"].find { |c| c.first == "fetch" }
    assert post, "the callback document must post the finalize"
    assert_equal "/account/confirm_username", post[1]
    assert_equal({ "token" => "TOK", "proof" => "SENT_SIG" }, JSON.parse(post[2]["body"]))
    assert_equal "CSRF", post[2]["headers"]["X-CSRF-Token"],
                 "this document's own meta tag is the PRIMARY source — it cannot be stale"

    assert_equal "/account", result["value"]["redirect"],
                 "studio-engine's callback navigates to result.value.redirect and falls back to '/'"
  end

  test "the inline transport leaves the finalize to the engine that is still awaiting it" do
    # THE DOUBLE-CONFIRM THIS PREVENTS. studio-engine's levelingActionModal posts
    # finalize_url the moment the hook resolves. Posting it here as well would
    # confirm the same rename twice.
    result = run_js(complete_call(strategy: "app-broadcasts", signed: "B58<1,2,3>"),
                    caller_alive: true)

    assert result["ok"], result["message"]
    assert_equal "SENT_SIG", result["value"]["proof"]
    assert_nil result["value"]["redirect"], "the inline path is not navigating anywhere — the modal is still open"
    refute_includes result["calls"].map(&:first), "fetch",
                    "the engine posts confirm_username on this transport; doing it here too confirms twice"
  end

  test "the inline transport still gets its progress copy" do
    result = run_js(complete_call(strategy: "app-broadcasts", signed: "B58<1,2,3>"),
                    caller_alive: true)

    progress = result["calls"].select { |c| c.first == "progress" }.map { |c| c[1] }
    assert_includes progress, "Confirming…"
  end

  test "the finalize surfaces the server's own refusal" do
    result = run_js(complete_call(strategy: "wallet-broadcasts", signature: "SIG"),
                    finalize_body: { "status" => "error", "message" => "Rename expired — please try again." })

    refute result["ok"]
    assert_equal "Rename expired — please try again.", result["message"]
  end

  test "a finalize that answers anything but saved is refused" do
    # THE SHAPE THE ENGINE CHECKS, mirrored. accounts#confirm_username answers
    # { status: "saved" }; treating a 200 with any other status as success is how
    # a failed rename reports itself as done.
    result = run_js(complete_call(strategy: "wallet-broadcasts", signature: "SIG"),
                    finalize_body: { "username" => "zed" })

    refute result["ok"]
    assert_match(/couldn't complete the step/i, result["message"])
  end

  # --- complete: the callback document, with nothing loaded ----------------

  test "complete runs on a document with NEITHER authedFetch NOR pollConfirmation" do
    # THE REGRESSION THIS FILE EXISTS FOR, and it is the exact incident shape the
    # contest-entry flow already paid for once. Both helpers ship in the DEFERRED
    # importmap module solana_utils.js, and studio-engine's phantom_callback view
    # dispatches from a bare inline script during body parse — so on the ONE
    # document complete() actually runs on, neither exists. A direct call to
    # either throws a TypeError after the user has approved in their wallet and
    # after resume() consumed the journal, leaving nothing to retry.
    result = run_js(complete_call(strategy: "wallet-broadcasts", signature: "SIG"),
                    authed_fetch: false, poll: false)

    assert result["ok"], result["message"]
    assert_equal "SIG", result["value"]["proof"]
    assert_equal "/account", result["value"]["redirect"]

    kinds = result["calls"].map(&:first)
    assert_includes kinds, "rpc", "the fallback poll must reach the RPC endpoint itself"
    rpc = result["calls"].find { |c| c.first == "rpc" }
    assert_equal "getSignatureStatuses", rpc[2]
    assert_equal "https://rpc.test", rpc[1]
    assert_includes kinds, "fetch", "and the finalize must still be posted through plain fetch"
  end

  test "a 401 on the callback document rejects rather than reporting a saved rename" do
    # Plain fetch answers a 401 Response where authedFetch answers falsy. The
    # normalisation in tmRenameFetch is what keeps `if (!resp)` meaning the same
    # thing on both documents; without it an expired session reads as a save.
    result = run_js(complete_call(strategy: "wallet-broadcasts", signature: "SIG"),
                    authed_fetch: false, finalize_status: 401)

    refute result["ok"], "a 401 must reject, not resolve"
    assert_match(/session expired/i, result["message"])
  end

  # --- the CSRF token: live tag first, the caller's as a fallback ----------

  test "a document with no csrf meta tag falls back to the token the caller journalled" do
    # EARNED, NOT DEFENSIVE. The first cut read the meta tag and nothing else, on
    # the reasoning that a session-bound token is always present. The e2e then
    # posted the finalize with an EMPTY header — its server disables forgery
    # protection, so csrf_meta_tags emits nothing at all (measured: the tag is
    # absent on '/' there too). An empty header would 422 a rename that is
    # already on-chain, which is the one failure this flow cannot retry.
    result = run_js(complete_call(strategy: "wallet-broadcasts", signature: "SIG"), csrf_meta: nil)

    assert result["ok"], result["message"]
    post = result["calls"].find { |c| c.first == "fetch" }
    assert_equal "CTX_CSRF", post[2]["headers"]["X-CSRF-Token"]
  end

  test "with neither source the header is empty rather than the string undefined" do
    # A literal "undefined" in the header is worse than an empty one: it reads as
    # a real token in a log and fails the same way.
    result = run_js(complete_call(strategy: "wallet-broadcasts", signature: "SIG", ctx_csrf: nil),
                    csrf_meta: nil)

    post = result["calls"].find { |c| c.first == "fetch" }
    assert_equal "", post[2]["headers"]["X-CSRF-Token"]
  end
end
