require "test_helper"
require "open3"
require "json"

# [unit] window.tmUsernameFinalize — the ONE call site, EXECUTED on both
# transports.
#
# WHAT THIS TIER OWNS that the intent test does not. The handlers are the flow;
# this is the chrome around it — which provider it asks for, what it declares to
# walletOps, what it says while a wallet app takes over, and what it does when
# the hop that should destroy this page does not happen. All of that is
# transport-dependent and none of it is reachable from the handlers.
#
# WHY IT IS DRIVEN RATHER THAN GREPPED. "Calls walletOps.run once" is a sentence
# a source scan can check and a behaviour it cannot: the interesting failures are
# a run() that declares the wrong expectedAccount, a redirect branch that
# RESOLVES (making studio-engine POST a finalize with an undefined proof), and a
# caller ledger left set after the attempt. Each of those reads fine.
class UsernameRenameCallSiteJsTest < ActiveSupport::TestCase
  FACTORIES = Rails.root.join("app/views/shared/_alpine_factories.html.erb")
  # The handoff watch is the runner's (window.tmWatchHandoff), shared with every
  # contest flow, so the runner is loaded into the same world as the call site.
  RUNNER = Rails.root.join("app/views/shared/_wallet_op_runner.html.erb")

  def runner_source
    src = File.read(RUNNER)
    src[(src.index("<script>") + "<script>".length)...src.rindex("</script>")]
  end

  def call_site_source
    src = File.read(FACTORIES)
    start = src.index("window.tmUsernameFinalize = async function")
    assert start, "could not find tmUsernameFinalize in the factories partial"
    finish = src.index("\n  };\n", start)
    assert finish, "could not bound tmUsernameFinalize"
    src[start..(finish + 4)]
  end

  # `transport:` 'inline' | 'redirect'. `hop:` whether the wallet app actually
  # took the universal link (only meaningful on the redirect transport).
  # `run_error:` a JS expression thrown out of walletOps.run instead of resolving.
  # `returns:` how the user comes back after a hop that took — nil (they never
  # do), "pageshow" (a bfcache restore) or "visible" (an app switch that never
  # unloaded the page).
  def run_js(transport: "inline", hop: true, run_error: nil, provider: nil, returns: nil)
    provider_js = provider || "{ transport: '#{transport}' }"

    run_body =
      if run_error
        "return Promise.reject(#{run_error});"
      else
        # The inline transport resolves with whatever complete() returned; the
        # redirect transport resolves with { suspended: true } after navigating.
        transport == "redirect" ? "return Promise.resolve({ suspended: true });"
                                : "return Promise.resolve({ proof: 'PROOF_SIG' });"
      end

    full = <<~JS
      global.window = global;
      var calls = [];
      var hidden = #{hop ? 'true' : 'false'};
      var listeners = {};
      var docListeners = {};
      global.document = {
        body: { dataset: { walletAddress: 'LINKED_ADDR', solanaCluster: 'devnet' } },
        get hidden() { return hidden; },
        // The csrf meta tag this document ships. The call site reads it to seed
        // ctx.csrfToken for the callback document, which may be served without
        // one of its own — see renameCsrfToken in shared/_username_rename_intent.
        querySelector: function (sel) { return sel.indexOf('csrf') !== -1 ? { content: 'PAGE_CSRF' } : null; },
        addEventListener: function (name, fn) { docListeners[name] = fn; },
        removeEventListener: function (name, fn) { if (docListeners[name] === fn) delete docListeners[name]; }
      };
      window.location = { origin: 'https://turf.test' };
      window.addEventListener = function (name, fn, o) { listeners[name] = fn; calls.push(['listen', name]); };
      window.removeEventListener = function (name, fn) {
        if (listeners[name] === fn) delete listeners[name];
        calls.push(['unlisten', name]);
      };
      window.walletProvider = { requireProvider: function () { calls.push(['requireProvider']); return #{provider_js}; } };
      window.tmUsernameRenameFinalizeUrl = '/account/confirm_username';
      window.SolanaStudio = { walletOps: { run: function (name, ctx, opts) {
        calls.push(['run', name, ctx, { expectedAccount: opts.expectedAccount, appUrl: opts.appUrl,
                                        redirectLink: opts.redirectLink, cluster: opts.cluster,
                                        providerTransport: opts.provider && opts.provider.transport }]);
        calls.push(['ledger_during_run', window.tmUsernameRenameCaller ? 'set' : 'null']);
        // THE HOP, simulated at the only moment it can happen: run() ends by
        // handing the OS a universal link, and the browser fires pagehide if
        // something takes it.
        if (#{hop ? 'true' : 'false'} && listeners['pagehide']) listeners['pagehide']();
        #{run_body}
      } } };

      #{runner_source}

      #{call_site_source}

      var RESULT;
      (async function () {
        var settled = false;
        // Past the runner's 2500ms grace window, so a hop that never took has
        // time to say so before this reads the attempt as pending.
        var timer = setTimeout(function () {
          if (settled) return;
          // NEVER RESOLVING IS THE CORRECT BEHAVIOUR on a successful redirect
          // hop; this is how the test observes it without hanging.
          process.stdout.write(JSON.stringify({ ok: null, pending: true, calls: calls }));
          process.exit(0);
        }, 4000);
        // THE WAY BACK, well after run() has resolved and the watch has started,
        // and well inside the grace window, as a quick abandon would be.
        var returns = #{returns.to_json};
        setTimeout(function () {
          if (returns === 'pageshow') {
            hidden = false;
            if (listeners['pageshow']) listeners['pageshow']({ persisted: true });
          }
          if (returns === 'visible') {
            hidden = false;
            if (docListeners['visibilitychange']) docListeners['visibilitychange']({});
          }
        }, 100);
        try { RESULT = { ok: true, value: await window.tmUsernameFinalize('AQID', { token: 'TOK', onProgress: function (l) { calls.push(['progress', l]); } }) }; }
        catch (e) { RESULT = { ok: false, message: e.message }; }
        settled = true;
        clearTimeout(timer);
        RESULT.calls = calls;
        RESULT.ledgerAfter = window.tmUsernameRenameCaller ? 'set' : 'null';
        process.stdout.write(JSON.stringify(RESULT));
      })();
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", full)
    assert status.success?, "node failed: #{stderr}"
    JSON.parse(stdout)
  end

  def run_call(result)
    result["calls"].find { |c| c.first == "run" }
  end

  # --- what the call site declares -----------------------------------------

  test "there is exactly one walletOps.run, under the name the callback looks up" do
    result = run_js

    runs = result["calls"].select { |c| c.first == "run" }
    assert_equal 1, runs.length, "the whole point of the migration is ONE call site"
    assert_equal "username_rename", runs.first[1],
                 "the journal carries this string and nothing else can find the handlers again"
  end

  test "it asks for a provider a phone can reach" do
    # requireInlineProvider — what this used to call — throws on a phone by
    # design, which is why the rename had no mobile path at all. requireProvider
    # answers with the redirect provider instead.
    result = run_js
    assert_includes result["calls"].map(&:first), "requireProvider"
    assert_equal "inline", run_call(result)[3]["providerTransport"]
  end

  test "the challenge and the engine's token ride in ctx, and the finalize URL with them" do
    # ctx is what walletOps journals, and it is the only thing complete() gets on
    # the callback document. A finalize URL left behind here is a rename that
    # confirms on-chain and never reaches the database.
    ctx = run_call(run_js)[2]

    assert_equal "AQID", ctx["challenge"]
    assert_equal "TOK", ctx["token"]
    assert_equal "/account/confirm_username", ctx["finalizeUrl"]
    # THE FALLBACK TOKEN, seeded here because only this document is certain to
    # have one. The callback page prefers its own tag and reaches for this only
    # when it has none — which is a real state, and one an e2e run found.
    assert_equal "PAGE_CSRF", ctx["csrfToken"]
    assert_equal JSON.parse(ctx.to_json), ctx, "ctx is journalled verbatim — it must survive JSON"
  end

  test "the expected account is the address this session is linked to" do
    # UX, not security: Anchor rejects a set_username signed by anyone else
    # regardless. What declaring it buys is a sentence naming both wallets, and
    # on the inline transport a check that runs BEFORE the signing prompt.
    opts = run_call(run_js)[3]

    assert_equal "LINKED_ADDR", opts["expectedAccount"]
    assert_equal "https://turf.test", opts["appUrl"]
    assert_equal "https://turf.test/auth/phantom/callback", opts["redirectLink"]
    assert_equal "devnet", opts["cluster"]
  end

  test "no signing, broadcasting or polling is left at the call site" do
    # THE DUPLICATION THIS RETIRED. A second hand-rolled copy of the on-chain arc
    # here is what rots: only the desktop half was ever exercised on a laptop.
    # Asserted against the extracted function, not the 2000-line partial around it.
    #
    # COMMENTS ARE STRIPPED FIRST, and that is not a convenience. The comment
    # above the provider call reads "requireProvider, NOT requireInlineProvider",
    # which is exactly the sentence a reader needs and exactly the substring this
    # guard would otherwise trip on. A guard that fires on its own documentation
    # gets weakened or deleted, so it is pointed at CODE.
    code = call_site_source.lines.reject { |l| l.strip.start_with?("//") }.join

    assert_includes code, "requireProvider()", "sanity: the stripped source must still contain the call"
    assert_not_includes code, "sendRawTransaction"
    assert_not_includes code, "signTransaction"
    assert_not_includes code, "pollConfirmation"
    assert_not_includes code, "solanaWeb3."
    assert_not_includes code, "requireInlineProvider"
  end

  # --- the inline transport ------------------------------------------------

  test "the inline transport returns the opaque proof studio-engine will POST" do
    # THE ENGINE'S CONTRACT, UNCHANGED BY THIS MIGRATION. levelingActionModal
    # awaits this hook and posts { token, proof } to finalize_url itself.
    result = run_js(transport: "inline")

    assert result["ok"], result["message"]
    assert_equal "PROOF_SIG", result["value"]
  end

  test "the caller ledger is set for the run and cleared after it" do
    # SET DURING: complete() reads it to know the engine is still awaiting and
    # will post the finalize itself. CLEARED AFTER: left set, a later redirect
    # rename resumed in this same tab would find it and skip its own finalize.
    result = run_js(transport: "inline")

    during = result["calls"].find { |c| c.first == "ledger_during_run" }
    assert_equal "set", during[1], "complete() runs inside run() and must find the ledger"
    assert_equal "null", result["ledgerAfter"], "the ledger belongs to ONE attempt"
  end

  test "the inline transport tells the user to approve, without naming a wallet it cannot see" do
    result = run_js(transport: "inline")
    labels = result["calls"].select { |c| c.first == "progress" }.map { |c| c[1] }

    assert_includes labels, "Approve in your wallet…"
    refute labels.any? { |l| l.include?("Phantom") },
           "the wallet may be Solflare or Backpack — the old copy named Phantom unconditionally"
  end

  # --- the redirect transport ----------------------------------------------

  test "a redirect hop that TAKES never resolves, so the engine cannot post an empty proof" do
    # THE SUBTLE ONE. runRedirect resolves with { suspended: true } after it
    # navigates — it does not hang. If this call site returned that, the engine's
    # leveling modal would POST confirm_username with proof === undefined, from a
    # document that is already unloading, while the real rename is still in
    # flight in the wallet app.
    result = run_js(transport: "redirect", hop: true)

    assert_nil result["ok"], "the hook must stay pending once the page is on its way out"
    assert_equal true, result["pending"]
  end

  test "a redirect hop that NEVER takes says so instead of spinning forever" do
    # The universal link was handed to the OS and nothing took it — no wallet app
    # installed. pagehide never fired and the document is not hidden, which is
    # the only evidence available that we are still here.
    result = run_js(transport: "redirect", hop: false)

    refute result["ok"], "a hop that did not happen must surface, not hang"
    assert_match(/wallet app did not open/i, result["message"])
    assert_match(/inside your wallet app's own browser/i, result["message"])
    assert_includes result["calls"].map(&:first), "unlisten",
                    "the pagehide listener must be removed once it has answered"
  end

  # --- the way back (/tasks/frozen-wallet-overlay-traps-user) ---------------
  #
  # THE SAME DOOR THE CONTEST BOARDS HAD, on the rename. A hop that took used to
  # leave this hook pending forever, so a user who came back from the wallet
  # without approving found the leveling modal still saving, its label still
  # "Opening your wallet app…", and Save disabled — and the caller ledger was
  # never cleared, because the finally below the await never ran. Coming back is
  # now a failure the engine can show, which re-enables Save and releases the
  # ledger.

  test "coming back from the bfcache without an answer rejects with a way to retry" do
    result = run_js(transport: "redirect", hop: true, returns: "pageshow")

    refute_nil result["ok"], "the hook must not stay pending once the user is back on this page"
    refute result["ok"], "a return without an answer is not a saved rename"
    assert_match(/no answer came back from your wallet/i, result["message"])
    assert_match(/try again/i, result["message"])
    assert_equal "null", result["ledgerAfter"],
                 "a ledger surviving the abandoned attempt would silence the NEXT rename's finalize"
  end

  test "coming back from an app switch that never unloaded the page rejects too" do
    result = run_js(transport: "redirect", hop: true, returns: "visible")

    refute_nil result["ok"]
    refute result["ok"]
    assert_match(/no answer came back from your wallet/i, result["message"])
    assert_equal "null", result["ledgerAfter"]
  end

  test "the redirect transport says a wallet app is opening, not that a wallet is signing" do
    result = run_js(transport: "redirect", hop: false)
    labels = result["calls"].select { |c| c.first == "progress" }.map { |c| c[1] }

    assert_includes labels, "Opening your wallet app…"
  end

  # --- failures ------------------------------------------------------------

  test "a user rejection reads as a rejection" do
    result = run_js(run_error: "Object.assign(new Error('User rejected the request.'), { code: 4001 })")

    refute result["ok"]
    assert_equal "Signature rejected", result["message"]
  end

  test "a wrong-wallet refusal keeps the remedy only this app knows" do
    # walletOps names BOTH wallets, which is more than the old hand-rolled check
    # did. But "switch accounts in your wallet" is the wrong remedy for a user
    # whose LINKED address is the stale side, and where this app relinks is this
    # app's business, not the gem's.
    result = run_js(run_error: "Object.assign(new Error('Wrong wallet — this account is linked to ABCD…WXYZ.'), { wrongAccount: true })")

    refute result["ok"]
    assert_match(/Wrong wallet/, result["message"])
    assert_match(/reconnect your wallet on the Account page/i, result["message"])
  end

  test "a failure still clears the caller ledger" do
    result = run_js(run_error: "new Error('boom')")

    refute result["ok"]
    assert_equal "null", result["ledgerAfter"],
                 "a ledger surviving a failed attempt would silence the NEXT rename's finalize"
  end

  test "an unreachable wallet surfaces the provider's own sentence" do
    # requireProvider throws noWalletMessage(), which differs by device. The call
    # site must not flatten it — that message IS the remedy.
    result = run_js(provider: "(function () { throw new Error('This browser cannot reach a wallet. Open this page inside your wallet app.'); })()")

    refute result["ok"]
    assert_match(/cannot reach a wallet/i, result["message"])
  end
end
