require "test_helper"
require "json"
require "open3"

# [docs-guard] Every failure mode docs/AUTH.md documents must be one an operator
# can actually meet.
#
# THE DEFECT THIS EXISTS FOR. AUTH.md's "Three things rethrow the ORIGINAL
# untouched" table listed the Wallet Standard rejection "Wallet not connected"
# among the modes that reach a surface with the wallet's own words. It cannot.
# That rejection is raised by the adapter's `signMessage`, and
# `solanaConnectAndVerify` calls `signMessage` only AFTER `connect()` has
# answered — at which point the `connected` guard added on 2026-09-07 (#587)
# sits ABOVE the `walletAnswered` guard in the same catch and substitutes its
# own sentence first. The row sent an operator hunting for a string the app
# cannot emit.
#
# WHY THIS FILE DOES NOT ASSERT THE ROW IS GONE. A guard that greps for absent
# prose dies the moment somebody rewords the table, and it says nothing about
# the code. This file instead DERIVES the reachable set by running the real
# helper, and compares the DOC's list against it. Delete a live row and it
# reddens; re-order the guards so a shadowed rejection becomes reachable again
# and it reddens too, naming the row that now has to come back.
#
# AND IT FAILS LOUD RATHER THAN EMPTY. Every parse has a floor: a regex that
# stops matching produces zero modes, and zero modes is a failure here, not a
# vacuous pass. Two controls prove the classifier still discriminates in both
# directions before any verdict is trusted.
class AuthFailureModeReachabilityTest < ActionDispatch::IntegrationTest
  DOC      = Rails.root.join("docs/AUTH.md")
  LAYOUT   = Rails.root.join("app/views/layouts/application.html.erb")
  PROVIDER = Rails.root.join("app/javascript/wallet_provider.js")
  MAPPER   = Rails.root.join("app/javascript/solana_errors.js")

  # What Rails sends when an exception escapes: a rendered page, not JSON.
  HTML_500 = "<!DOCTYPE html>\n<html><body><h1>We're sorry, but something went wrong.</h1></body></html>".freeze

  # --- what the DOC claims ---------------------------------------------------

  # The strings AUTH.md lists on its `walletAnswered` rethrow row. Keyed on the
  # TAG NAME rather than on surrounding prose, so a rewritten sentence still
  # parses; a row that loses the tag parses to nothing and trips the floor below.
  def documented_wallet_answered
    @documented_wallet_answered ||= begin
      row = DOC.read.lines.find { |l| l.start_with?(" ") && l.lstrip.start_with?("|") && l.include?("`walletAnswered`") }
      refute_nil row, "docs/AUTH.md no longer has a table row naming the `walletAnswered` tag — " \
                      "this file cannot audit a table it cannot find"
      row.split("|")[1].to_s.scan(/"([^"]+)"/).flatten.sort
    end
  end

  # --- what the CODE can raise ----------------------------------------------

  # Every `_walletAnswered(new Error('...'))` site in the adapter, paired with
  # the provider method that raises it. Read from source so a new tagged
  # rejection is audited the day it lands, without editing this file.
  def tagged_sites
    @tagged_sites ||= begin
      method = nil
      found  = []
      PROVIDER.read.each_line do |line|
        m = line.match(/^\s{2,8}(\w+): function\s*\(/)
        method = m[1] if m
        line.scan(/_walletAnswered\(new Error\('([^']+)'\)\)/).each do |(message)|
          refute_nil method, "could not attribute the tagged rejection #{message.inspect} to a provider method"
          found << { "message" => message, "method" => method }
        end
      end
      found
    end
  end

  # --- driving the real helper ----------------------------------------------

  # The helper as the BROWSER receives it. Lifted from the rendered page by
  # brace matching rather than read off the .erb, so a layout that stopped
  # shipping the helper fails here instead of passing on a stale copy.
  def helper_js
    @helper_js ||= begin
      get "/signin"
      assert_response :success

      marker = "window.solanaConnectAndVerify = async function(walletName, opts) {"
      start = response.body.index(marker)
      refute_nil start, "the layout no longer inlines solanaConnectAndVerify — has it moved?"

      open_brace = start + marker.length - 1
      depth = 0
      finish = nil
      (open_brace...response.body.length).each do |i|
        case response.body[i]
        when "{" then depth += 1
        when "}" then (depth -= 1) == 0 && (finish = i)
        end
        break if finish
      end
      refute_nil finish, "could not brace-match the helper"

      response.body[start..finish] + ";"
    end
  end

  # Run every case through the REAL helper and the REAL mapper in one Node
  # process, and read each outcome exactly the way modals/_wallet_setup.html.erb
  # reads it — because that surface, not this file, is what decides whether a
  # wallet's words survive to an operator.
  def outcomes
    @outcomes ||= begin
      cases = tagged_sites.map do |site|
        { "id" => "tagged:#{site['message']}", "method" => site["method"], "message" => site["message"], "tag" => "walletAnswered" }
      end
      cases << { "id" => "control:decline", "method" => "connect", "message" => "User rejected the request.", "code" => 4001 }
      cases << { "id" => "control:substituted", "method" => "connect", "message" => "Unexpected error" }

      script = <<~JS
        globalThis.window = globalThis;
        globalThis.document = { querySelector: function () { return null; } };
        globalThis.encodeBase58 = function () { return 'sig'; };
        window.location = { host: 'turf.test' };

        (0, eval)(#{MAPPER.read.to_json});
        (0, eval)(#{helper_js.to_json});

        var reports = [];
        window.reportWalletFailure = function (stage, provider, raw, mapped) {
          reports.push({ stage: stage, raw: raw, mapped: mapped });
        };

        var HTML = #{HTML_500.to_json};
        var CASES = #{cases.to_json};

        // A wallet that works, so each case changes exactly one thing.
        function makeProvider(spec, supportsSignIn) {
          function boom() {
            var e = new Error(spec.message);
            if (spec.tag) e[spec.tag] = true;
            if (spec.code) e.code = spec.code;
            return Promise.reject(e);
          }
          function guarded(name, ok) {
            return function () { return spec.method === name ? boom() : ok(); };
          }
          return {
            name: 'phantom',
            supportsSignIn: function () { return supportsSignIn; },
            // A signIn that is UNUSABLE, not declined — the helper swallows this
            // and takes the two-step fallback, which is the modern Phantom shape.
            signIn: guarded('signIn', function () { return Promise.reject(new Error('signIn unavailable')); }),
            connect: guarded('connect', function () {
              return Promise.resolve({ publicKey: { toBase58: function () { return 'PubKeyBase58'; } } });
            }),
            signMessage: guarded('signMessage', function () {
              return Promise.resolve({ signature: new Uint8Array(64) });
            }),
            signTransaction: guarded('signTransaction', function () { return Promise.resolve({}); })
          };
        }

        function jsonResponse(body) {
          return new Response(JSON.stringify(body), { status: 200, headers: { 'Content-Type': 'application/json' } });
        }

        // Both legs answer well unless a case says otherwise, so a failure in
        // the wallet is never confused with a failure of ours.
        function server(opts) {
          return async function (url) {
            if (String(url).indexOf('/auth/solana/nonce') === 0) {
              if (opts.nonce === 'offline') throw new TypeError('Failed to fetch');
              return jsonResponse({ nonce: 'NONCE' });
            }
            if (opts.verify === 'html500') {
              return new Response(HTML, { status: 500, headers: { 'Content-Type': 'text/html' } });
            }
            return jsonResponse({ success: true });
          };
        }

        async function drive(spec, supportsSignIn, opts) {
          reports = [];
          globalThis.fetch = server(opts || {});
          var provider = makeProvider(spec, supportsSignIn);
          window.walletProvider = { get: function () { return provider; }, detect: function () { return provider; } };
          try {
            await window.solanaConnectAndVerify('phantom', {});
            return { resolved: true, reports: reports };
          } catch (e) {
            // modals/_wallet_setup.html.erb, verbatim.
            var raw = (e && e.message) || '';
            var shown = (e && e.code === 4001) ? 'Signature rejected' : (raw || 'Connection failed');
            shown = window.parseSolanaError(shown);
            return {
              resolved: false,
              raw: raw,
              shown: shown,
              suppressed: !!(e && e.walletFailureReported),
              reports: reports
            };
          }
        }

        var out = { cases: {}, nonce_offline: null, verify_html_500: null };
        for (var i = 0; i < CASES.length; i++) {
          var spec = CASES[i];
          out.cases[spec.id] = {
            fallback: await drive(spec, false, {}),
            sign_in:  await drive(spec, true, {})
          };
        }
        // The other two documented rethrows, driven on a working wallet.
        var healthy = { method: 'none', message: 'never thrown' };
        out.nonce_offline   = await drive(healthy, false, { nonce: 'offline' });
        out.verify_html_500 = await drive(healthy, false, { verify: 'html500' });

        console.log(JSON.stringify(out));
      JS

      stdout, stderr, status = Open3.capture3("node", "--input-type=module", "--eval", script)
      assert status.success?, stderr
      JSON.parse(stdout.lines.map(&:strip).reject(&:empty?).last)
    end
  end

  # A tagged rejection is REACHABLE when the surface catches the wallet's own
  # words with nothing substituted for them. Both wallet shapes must agree; a
  # disagreement means the two branches diverged and the verdict is not safe to
  # read.
  def reachable_untouched(id, expected_message)
    both = outcomes.fetch("cases").fetch(id)
    verdicts = %w[fallback sign_in].map do |path|
      r = both.fetch(path)
      !r["resolved"] && r["raw"] == expected_message && !r["suppressed"]
    end
    assert_equal verdicts.first, verdicts.last,
                 "#{id} reaches the surface differently on the signIn and fallback paths — " \
                 "one of them changed and the doc cannot describe both"
    verdicts.first
  end

  # --- the floors, first -----------------------------------------------------

  test "both sides of the audit parsed something to compare" do
    # WITHOUT THIS EVERY GREEN BELOW IS VACUOUS. A reworded table or a renamed
    # helper turns both sets empty, and empty == empty passes while proving
    # nothing. This has bitten four times this cycle; it reddens here instead.
    assert_operator tagged_sites.size, :>=, 2,
                    "expected at least the two `_walletAnswered` sites in wallet_provider.js — " \
                    "found #{tagged_sites.size}; the source parse has stopped matching"
    assert_operator documented_wallet_answered.size, :>=, 1,
                    "docs/AUTH.md's `walletAnswered` row lists no quoted rejection at all"
    assert_equal tagged_sites.map { |s| s["message"] }.uniq.size, tagged_sites.size,
                 "two tagged sites raise the same string — the audit cannot tell them apart"
  end

  test "the classifier still discriminates in both directions" do
    # THE CONTROLS. A classifier that answered "unreachable" to everything would
    # pass an empty table, and one that answered "reachable" to everything would
    # pass any table at all. Neither can survive both of these.
    assert reachable_untouched("control:decline", "User rejected the request."),
           "a 4001 decline must still reach the surface with the wallet's own words — " \
           "if it does not, this file's notion of reachable is broken, not the table"
    refute reachable_untouched("control:substituted", "Unexpected error"),
           "an unusable wallet's generic string must still be REPLACED before the surface — " \
           "if it now arrives untouched, the substitution has regressed"
  end

  # --- the audit itself ------------------------------------------------------

  test "AUTH.md lists exactly the walletAnswered rejections an operator can meet" do
    reachable = tagged_sites.select { |s| reachable_untouched("tagged:#{s['message']}", s["message"]) }
                            .map { |s| s["message"] }.sort
    shadowed  = tagged_sites.map { |s| s["message"] }.sort - reachable

    assert_equal reachable, documented_wallet_answered, <<~MSG
      docs/AUTH.md's `walletAnswered` rethrow row disagrees with what the code can deliver.

        reachable at a surface, untouched : #{reachable.inspect}
        listed in AUTH.md                 : #{documented_wallet_answered.inspect}
        raised but never reaching a surface: #{shadowed.inspect}

      A listed-but-unreachable string sends an operator after a cause that cannot
      occur. A reachable-but-unlisted one leaves a real row undocumented — most
      likely because a guard moved: `solanaConnectAndVerify`'s `connected` guard
      sits ABOVE its `walletAnswered` guard, so anything raised after connect()
      answers is substituted before the tag is ever read.
    MSG
  end

  test "the shadowed rejections are reported under their own stage, not lost" do
    # The corrected row says these are SUBSTITUTED rather than dead: an operator
    # still sees the failure, under a different stage and with the wallet's words
    # in `raw`. That is what makes dropping them from the rethrow row honest.
    tagged_sites.reject { |s| reachable_untouched("tagged:#{s['message']}", s["message"]) }.each do |site|
      report = outcomes.fetch("cases").fetch("tagged:#{site['message']}").fetch("fallback").fetch("reports").last
      refute_nil report, "#{site['message'].inspect} is neither rethrown nor reported — the failure is invisible"
      assert_equal site["message"], report.fetch("raw"),
                   "the wallet's own words must still be captured before the substitution"
      assert_equal "connect_verify_signature", report.fetch("stage"),
                   "a rejection raised after connect() answered belongs to the signing diagnosis"
    end
  end

  # --- the other two documented rethrow rows --------------------------------

  test "a nonce fetch that never arrived still reaches the surface untouched" do
    result = outcomes.fetch("nonce_offline")
    refute result["resolved"], "the helper must reject when it cannot get a nonce"
    assert_equal "Failed to fetch", result.fetch("raw"),
                 "AUTH.md documents this rejection as arriving with its own words"
    refute result.fetch("suppressed"), "a network failure of the USER'S must stay reportable"
  end

  test "an HTML-bodied 500 from the VERIFY leg names our server" do
    # THIS ROW WAS PINNED TO THE DEFECT, AND THE PIN HAS NOW BEEN TURNED OVER.
    # Until 2026-09-09 this test asserted that an unreadable verify body reached
    # the user as the mapper's balance sentence, and said in as many words that
    # reddening because someone fixed the leg would be good news requiring
    # AUTH.md's triage row to change in the same commit. That is what happened
    # (`/tasks/verify-leg-repeats-nonce-bug`), so the assertion now guards the
    # FIX instead of the exposure — a pin that keeps asserting a closed defect is
    # how a suite starts demanding the bug back.
    #
    # WHAT IT DEFENDS NOW. The substitution lives inside the verify POST's
    # `.json()`. Revert it, gate it on `!r.ok`, or hoist it around the fetch, and
    # the user is back to reading parser noise or being mislabelled — the two
    # directions test/views/verify_server_failure_copy_test.rb mutates in detail.
    # Here it is checked once more, through the DERIVED path this file uses for
    # everything else, so the doc audit and the behaviour cannot drift apart.
    result = outcomes.fetch("verify_html_500")
    refute result["resolved"], "an unreadable verify body must still reject"

    server_copy = LAYOUT.read[/^\s*var verifyServerCopy = '(.*)';$/, 1]
    refute_nil server_copy, "the verify leg's server sentence has moved — this row cannot audit what it cannot find"
    server_copy = server_copy.gsub('\\u2014', "—")

    refute_match(/\AUnexpected token '<'/, result.fetch("raw"),
                 "the verify leg's .json() guard has regressed — an HTML-bodied 500 is reaching " \
                 "the surface as V8 parser noise again, and AUTH.md documents this leg as CLOSED")
    assert_equal server_copy, result.fetch("shown"),
                 "AUTH.md documents this as naming our server, not the user's balance"

    transaction_sentence = MAPPER.read[/return "(Wallet couldn't process the transaction[^"]*)";/, 1]
    refute_nil transaction_sentence, "the mapper's generic branch has moved"
    refute_equal transaction_sentence, result.fetch("shown"),
                 "our outage must not read as the user's wallet being short of funds"
    assert result.fetch("suppressed"),
           "a 500 of ours is already in the server's log — the substituted error must carry " \
           "walletFailureReported so no surface files a raw == mapped row for it"
  end
end
