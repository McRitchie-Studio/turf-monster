require "test_helper"
require "json"
require "open3"

# [component] What a VERIFY-endpoint failure of OURS says to a paying user who
# has ALREADY SIGNED.
#
# THE DEFECT, MEASURED. `solanaConnectAndVerify` ended with a bare
# `return await (await fetch(verifyUrl, ...)).json()` sitting outside BOTH `try`
# blocks. `/auth/solana/verify` (or `/account/link_solana`) answers with an HTML
# body — see WHICH FAULTS below — so `.json()` rejects with V8's
# "Unexpected token '<', \"<!DOCTYPE \"... is not valid JSON",
# `parseSolanaError`'s generic branch matches /^unexpected/i, and the user is
# told to check their wallet connection and their USDC balance.
#
# WHICH FAULTS SEND AN UNREADABLE BODY. Not "any unhandled exception" — this
# file said that until 2026-09-09 and it is FALSE on BOTH endpoints.
# `SolanaSessionsController#verify` and `AccountsController#link_solana` each END
# in `rescue StandardError => e; render json: { error: e.message }, status: :unprocessable_entity`,
# so an exception raised INSIDE either action reaches the browser as JSON 422 and
# `.json()` parses it. THREE things do send HTML, and TWO ARRIVE AT STATUS 200:
#
#   * THE ENGINE CATCH-ALL. `Studio::ErrorHandling` registers
#     `rescue_from StandardError`, so whatever the actions' own rescues do not
#     claim — a raise in a before_action, or in `#nonce`, which has no local
#     rescue — reaches `handle_unexpected_error`, whose production branch
#     `respond_to`s. This fetch sends no Accept header, so it takes `format.html`:
#     a 302 to root, which `fetch` FOLLOWS to HTML at status 200.
#   * THE OPSEC-045 FORCED LOGOUT, the same shape one layer earlier — a 302 to
#     /signin, followed to HTML at status 200. Measured end to end 2026-09-09.
#   * A FAULT OUTSIDE `rescue_from`'s REACH (middleware, routing), which
#     `ActionDispatch::PublicExceptions` renders as the 500 error page.
#
# `r.ok` is TRUE on the first two, which is the whole argument for the
# substitution sitting inside `.json()`. Correcting the sentence matters beyond
# accuracy: the false version made the guard look like it covered the in-action
# exception too, which is how the next reader concludes the JSON-422 path is
# handled here and stops checking it.
#
# WORSE THAN THE NONCE CASE, WHICH IS WHY IT GETS ITS OWN FILE. The nonce fetch
# happens BEFORE the user signs. This one happens AFTER the signature succeeded.
# A user completes a wallet signature, our server faults, and we answer with
# balance advice — on a real-money product, at the moment they have most reason
# to believe something was taken. The step that proved the wallet fine is the
# step immediately before the accusation.
#
# READ WHAT THE USER READS, NOT WHICH BRANCH RAN. A test asserting a guard
# exists, or that a tag was set, passes on a page that still prints the balance
# sentence — the string only becomes wrong after the mapper runs, and the mapper
# runs at the SURFACE. So this file lifts the helper out of the RENDERED page,
# drives it in Node against a real 500 Response with an HTML body, maps the
# rejection exactly the way modals/_wallet_setup.html.erb does, and asserts the
# decoded sentence a human would be looking at.
#
# BOTH WALLET PATHS, AND SINCE 2026-09-09 THAT IS ENFORCED RATHER THAN ASSERTED
# IN A COMMENT. Unlike the nonce leg — where the `signIn` branch awaits above its
# `try` and a guard-local fix would have missed Phantom — the signIn branch and
# the connect + signMessage fallback both fall THROUGH to this one fetch, so a
# substitution here covers every wallet.
#
# THE CLAIM USED TO BE UNBACKED, which is worse than not making it: it tells the
# next reader the coverage exists and stops them adding it. Forcing `useSignIn`
# true or false in the layout left this whole file GREEN (Carl's M6 and M7 on
# PR 644 both SURVIVED), because the mock answered `signIn` and
# `connect` + `signMessage` with the same address and the same signature.
# Identical outcomes cannot discriminate two branches. Two things fix it:
#
#   * the mock is now STRICT — a `signIn`-capable wallet REFUSES `connect`, and a
#     wallet without `signIn` refuses `signIn` — so a helper that takes the wrong
#     branch fails on the SENTENCE, in the tests that already exist;
#   * every drive records which wallet methods it actually reached, and one test
#     asserts them, which catches the mutation the strict mock cannot: a forced
#     `useSignIn = true` is swallowed by the signIn `catch`, falls back, and ends
#     in the identical place.
#
# THAT WITNESS IS A FLOOR, NOT A REPLACEMENT. A test that checks which branch ran
# passes on a page that still says the wrong thing, so it never stands in for the
# decoded-sentence assertions below — it proves each of those was collected from
# the path whose name it carries.
class VerifyServerFailureCopyTest < ActionDispatch::IntegrationTest
  LAYOUT = Rails.root.join("app/views/layouts/application.html.erb")
  MAPPER = Rails.root.join("app/javascript/solana_errors.js")

  # What Rails actually sends when a fault escapes the action and the request
  # asked for no JSON: a rendered page. The doctype is the whole discriminator —
  # a JSON-bodied 500 parses fine and fails later, somewhere else, saying
  # something else.
  HTML_500 = "<!DOCTYPE html>\n<html><body><h1>We're sorry, but something went wrong.</h1></body></html>".freeze

  # ...and what the SAME fault sends when the request DOES ask for JSON. Measured
  # 2026-09-09 by calling ActionDispatch::PublicExceptions directly: no Accept
  # header, `*/*` and `text/html` all produce HTML_500 above; `application/json`
  # produces exactly this. It parses, so the guard under test never fires on it.
  # This is not decoration — it is the body the fake server hands back when the
  # rendered helper asks for JSON, and it is what makes finding 3 fail loudly
  # instead of silently deleting the coverage.
  JSON_500 = { "status" => 500, "error" => "Internal Server Error" }.freeze

  # A REAL rejection this endpoint answers with, carried in a VALID JSON body at
  # a NON-2xx status. SolanaSessionsController#verify renders exactly this shape
  # for an expired nonce and a bad signature (401) and for the age attestation
  # (422). It is the reason the substitution is NOT gated on `r.ok`.
  SERVER_REJECTION = "Nonce expired".freeze

  # The sentence this task exists to keep off a sign-in surface. Read from the
  # mapper rather than typed here, so a reworded mapper cannot leave this file
  # asserting against a string nothing emits any more.
  def transaction_sentence
    @transaction_sentence ||= MAPPER.read[/return "(Wallet couldn't process the transaction[^"]*)";/, 1].tap do |found|
      refute_nil found, "the mapper's generic transaction branch has moved — this file cannot verify anything without it"
    end
  end

  # The literal the layout composes, decoded the way a browser decodes it. NEVER
  # a copy of the copy: a hardcoded duplicate cannot fail when the sentence
  # changes, which is exactly the coupling under test.
  def server_copy
    @server_copy ||= begin
      line = LAYOUT.read[/^\s*var verifyServerCopy = '(.*)';$/, 1]
      refute_nil line, "the verify server sentence must be composed once, as a one-line literal"
      line.gsub('\\u2014', "—")
    end
  end

  # The helper as the BROWSER receives it, lifted from the rendered page by brace
  # matching. Reading the .erb source instead would pass over a layout that
  # stopped shipping the helper at all.
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

  # Drive the real helper against real Response objects. `.json()` rejects here
  # for the same reason and in the same engine as it does in Chrome, so the raw
  # string under test is V8's, not one this file made up.
  def outcomes
    @outcomes ||= begin
      script = <<~JS
        globalThis.window = globalThis;
        globalThis.document = { querySelector: function () { return null; } };
        globalThis.encodeBase58 = function () { return 'sig'; };
        window.location = { host: 'turf.test' };

        (0, eval)(#{MAPPER.read.to_json});
        (0, eval)(#{helper_js.to_json});

        var HTML = #{HTML_500.to_json};
        var REJECTION = #{SERVER_REJECTION.to_json};

        // A WALLET THAT WORKS ALL THE WAY THROUGH. The verify leg is only
        // reachable AFTER a successful signature, so every case here signs
        // cleanly and changes exactly one thing: what the verify POST answers.
        function signedMessage() {
          return 'turf.test wants you to sign in with your Solana account:\\n' +
                 'PubKeyBase58\\n\\nSign in to Turf Monster\\n\\nNonce: NONCE';
        }

        // WHICH WALLET METHODS THE HELPER ACTUALLY REACHED, for the drive in
        // flight. Reset per drive. This is what makes "both wallet paths" a
        // measured fact rather than a comment.
        var calls = [];

        // STRICT ON BOTH SIDES. Each provider answers only the calls its own
        // path is supposed to make and REFUSES the other path's, so a helper
        // that takes the wrong branch does not quietly produce an identical
        // result — it fails, and it fails in the sentence assertions that were
        // already here rather than in a new bookkeeping one.
        function provider(supportsSignIn) {
          return {
            name: 'phantom',
            supportsSignIn: function () { return supportsSignIn; },
            signIn: async function () {
              calls.push('signIn');
              if (!supportsSignIn) {
                // Reached only if the helper ignored supportsSignIn(). A real
                // wallet without the feature does not expose this at all.
                throw new Error('signIn reached on a wallet that does not support it');
              }
              return {
                address: 'PubKeyBase58',
                signedMessage: new TextEncoder().encode(signedMessage()),
                signature: new Uint8Array(64)
              };
            },
            connect: async function () {
              calls.push('connect');
              // THE MUTATION KILLER FOR A FORCED `useSignIn = false`. A
              // signIn-capable wallet must never be asked for two prompts; if
              // it is, this rejects and every *_sign_in assertion above reddens
              // on the copy, which is the level that matters.
              if (supportsSignIn) throw new Error('connect reached on a signIn-capable wallet');
              return { publicKey: { toBase58: function () { return 'PubKeyBase58'; } } };
            },
            signMessage: async function () {
              calls.push('signMessage');
              if (supportsSignIn) throw new Error('signMessage reached on a signIn-capable wallet');
              return { signature: new Uint8Array(64) };
            }
          };
        }

        function jsonResponse(body, status) {
          return new Response(JSON.stringify(body), {
            status: status || 200,
            headers: { 'Content-Type': 'application/json' }
          });
        }

        // WHAT THE `Accept` HEADER THE HELPER SENDS ACTUALLY BUYS. Measured
        // 2026-09-09 against ActionDispatch::PublicExceptions: the SAME 500 is
        // the rendered error PAGE for no Accept header, `*/*` and `text/html`,
        // and is JSON_500 for `application/json`. So the fake answers off the
        // header the RENDERED helper really sent, exactly the way Rails does.
        //
        // FINDING 3, AND WHY THIS IS NOT PEDANTRY. Adding
        // `Accept: application/json` to the verify fetch is a one-line tidy-up
        // that two sibling call sites in the layout already make. It would make
        // this endpoint answer JSON on the error path, `.json()` would RESOLVE,
        // the substitution would never run — and against a fake that always
        // returned HTML regardless of headers, every test in this file would
        // have stayed green while covering nothing. A contributor would have
        // deleted the coverage with no signal. Now the fixture depends on the
        // real header, so it reddens.
        function acceptOf(init) {
          var headers = (init && init.headers) || {};
          return headers['Accept'] || headers['accept'] || '';
        }

        function railsError(accept) {
          // indexOf, not a regex: this is inside a Ruby heredoc, where a `\/`
          // escape is eaten before Node ever sees it.
          if (String(accept).toLowerCase().indexOf('application/json') !== -1) {
            return new Response(JSON.stringify(#{JSON_500.to_json}), {
              status: 500,
              headers: { 'Content-Type': 'application/json' }
            });
          }
          return new Response(HTML, { status: 500, headers: { 'Content-Type': 'text/html' } });
        }

        // The Accept header the helper sent on the VERIFY POST specifically —
        // the nonce fetch is skipped so its own (absent) header cannot be read
        // as this one's.
        var acceptSeen = null;

        // The nonce leg always answers well: a failure of OURS on the verify leg
        // must never be confused with one on the leg that already has a guard.
        function server(verify) {
          return async function (url, init) {
            if (String(url).indexOf('/auth/solana/nonce') === 0) return jsonResponse({ nonce: 'NONCE' });
            acceptSeen = acceptOf(init);
            return verify(init);
          };
        }

        var VERIFY = {
          html_500:   function (init) { return railsError(acceptOf(init)); },
          offline:    function () { throw new TypeError('Failed to fetch'); },
          // A NON-2xx WITH A BODY WORTH READING. This is what an `r.ok` guard
          // would destroy, and the reason the substitution sits inside .json().
          rejection:  function () { return jsonResponse({ error: REJECTION }, 401); },
          ok:         function () { return jsonResponse({ success: true, redirect: '/' }); }
        };

        async function drive(verifyName, supportsSignIn) {
          calls = [];
          acceptSeen = null;
          globalThis.fetch = server(VERIFY[verifyName]);
          window.walletProvider = {
            get: function () { return provider(supportsSignIn); },
            detect: function () { return provider(supportsSignIn); }
          };
          try {
            var result = await window.solanaConnectAndVerify('phantom', {});
            return { resolved: true, result: result, calls: calls, accept: acceptSeen };
          } catch (e) {
            // modals/_wallet_setup.html.erb, verbatim: the wallet's string, then
            // the mapper, then onto the page as `this.error`.
            var raw = (e && e.message) || '';
            var shown = (e && e.code === 4001) ? 'Signature rejected' : (raw || 'Connection failed');
            shown = window.parseSolanaError(shown);
            return {
              resolved: false, raw: raw, shown: shown,
              reported: !!(e && e.walletFailureReported),
              calls: calls, accept: acceptSeen
            };
          }
        }

        // THE CONTROL, run in the same engine on the same body: what .json()
        // ACTUALLY rejects with, and what the mapper still does with it.
        var parseRejection = null;
        try {
          await new Response(HTML, { status: 500 }).json();
        } catch (e) {
          parseRejection = e.message;
        }

        // THE SECOND CONTROL, and it carries the same weight as the first. If
        // `railsError` stopped discriminating on the header, the Accept
        // assertion below would pass while proving nothing — the exact
        // unfalsifiable shape this file already guards against for the parse
        // rejection.
        var acceptControl = {
          without: (await railsError('').text()).slice(0, 15),
          with_json: await railsError('application/json').text()
        };

        var out = {
          parse_rejection: parseRejection,
          control_mapped: window.parseSolanaError(parseRejection),
          accept_control: acceptControl
        };
        for (var name in VERIFY) {
          out[name + '_sign_in']  = await drive(name, true);
          out[name + '_fallback'] = await drive(name, false);
        }
        console.log(JSON.stringify(out));
      JS

      stdout, stderr, status = Open3.capture3("node", "--input-type=module", "--eval", script)
      assert status.success?, stderr
      JSON.parse(stdout.lines.map(&:strip).reject(&:empty?).last)
    end
  end

  # --- the control: the shape is real and the mapper still mis-maps it --------

  test "an HTML-bodied 500 really does reject the way the mapper mis-reads" do
    # WITHOUT THIS, EVERY GREEN BELOW IS UNFALSIFIABLE. If the body stopped
    # producing the /^unexpected/i shape — a different doctype, a changed engine
    # message — the tests below would pass while proving nothing, because the
    # defect would no longer be reachable through the fixture.
    assert_match(/\AUnexpected token '<'/, outcomes.fetch("parse_rejection"),
                 "the HTML body must still make .json() reject with the string the mapper matches")
    assert_equal transaction_sentence, outcomes.fetch("control_mapped"),
                 "the mapper must still rewrite that raw string into balance advice — " \
                 "this is the mis-mapping the substitution exists to get in front of"
  end

  test "the fixture server really does answer by Accept, both ways" do
    # THE CONTROL UNDER FINDING 3's GUARD. The Accept assertion below is only
    # worth anything while the fake actually discriminates on the header. If it
    # regressed to always returning HTML, that test would pass on a helper that
    # HAD added the header — which is the precise failure it exists to prevent.
    control = outcomes.fetch("accept_control")
    assert_equal "<!DOCTYPE html>", control.fetch("without"),
                 "with no Accept header the fixture must send the rendered page — the body .json() rejects on"
    assert_equal JSON_500.to_json, control.fetch("with_json"),
                 "with Accept: application/json the SAME fault must come back as parseable JSON"
  end

  test "the verify POST asks for no JSON, which is what keeps the guard armed" do
    # FINDING 3, 2026-09-09 — the hardening that would silently disarm this file.
    #
    # `Accept: application/json` on the verify fetch is a one-line change, and
    # two sibling call sites in the same layout already send it, so it reads as
    # tidying up an inconsistency. It is not. Measured against
    # ActionDispatch::PublicExceptions: the header flips the error path from the
    # rendered page to {"status":500,"error":"Internal Server Error"}, which
    # PARSES. `.json()` then resolves, `verifyServerCopy` is never substituted,
    # and a user who has already signed reads a bare "Internal Server Error"
    # instead of being told their signature moved no funds.
    #
    # WHY THIS TEST AND NOT JUST THE ONES BELOW. The ones below now redden too,
    # because the fixture answers by header — but they would redden with a
    # message about copy, sending the next reader hunting a sentence. This one
    # names the cause.
    #
    # THE HEADER IS NOT FORBIDDEN, IT IS COUPLED. Adding it deliberately means
    # re-aiming the guard in the same diff, and that is a real design problem
    # rather than a line: a JSON error body has to be told apart by STATUS, and
    # this endpoint answers 401 and 422 with JSON bodies the user MUST read (see
    # "a real server rejection still reaches the user in its own words"). Whoever
    # takes that on changes this test on purpose.
    %w[html_500_sign_in html_500_fallback ok_sign_in ok_fallback].each do |path|
      assert_equal "", outcomes.fetch(path).fetch("accept"),
                   "the verify POST must send no Accept header (#{path}) — it now sends " \
                   "#{outcomes.fetch(path).fetch('accept').inspect}, which makes our 500 come back " \
                   "as JSON, resolves .json(), and disarms the substitution this file guards"
    end
  end

  test "each path's rows really were collected from that path" do
    # FINDING 1, 2026-09-09. This file claimed to cover both wallet paths and
    # nothing discriminated: forcing `useSignIn` true or false in the layout left
    # every assertion green (Carl's M6 and M7 on PR 644 both SURVIVED), because
    # the mock answered `signIn` and `connect` + `signMessage` with the same
    # address and the same signature. A claim of coverage that no assertion backs
    # is worse than silence — it stops the next reader adding the missing test.
    #
    # NOT A SUBSTITUTE FOR READING THE SENTENCE. A test that checks which branch
    # ran passes on a page that still prints the balance advice, so this never
    # stands in for the decoded-copy assertions. It is the floor under them: it
    # proves every `*_sign_in` row above came from the ONE-prompt path and every
    # `*_fallback` row from connect + signMessage, which is exactly what the
    # convergence argument in the header rests on.
    #
    # THE STRICT MOCK CANNOT DO THIS ALONE. A forced `useSignIn = true` is
    # swallowed by the signIn branch's own `catch`, drops into the fallback, and
    # lands in the identical place with the identical copy. Only the record of
    # which wallet methods were reached tells the two apart.
    %w[ok html_500 offline rejection].each do |shape|
      assert_equal %w[signIn], outcomes.fetch("#{shape}_sign_in").fetch("calls"),
                   "a signIn-capable wallet must sign in with ONE prompt (#{shape}) — a `connect` " \
                   "here means the helper fell back and the #{shape}_sign_in row describes the fallback"
      assert_equal %w[connect signMessage], outcomes.fetch("#{shape}_fallback").fetch("calls"),
                   "a wallet without signIn must take connect + signMessage (#{shape}) — a `signIn` " \
                   "here means the helper ignored supportsSignIn() and the #{shape}_fallback row " \
                   "describes the signIn branch"
    end
  end

  test "the happy path still resolves the parsed server result" do
    # The floor under every rejection test here: if the helper stopped resolving
    # a good verify answer, the whole flow would be broken and the greens below
    # would be describing a sign-in nobody can complete.
    %w[ok_sign_in ok_fallback].each do |path|
      result = outcomes.fetch(path)
      assert result["resolved"], "a 200 with a JSON body must still resolve (#{path})"
      assert_equal({ "success" => true, "redirect" => "/" }, result.fetch("result"),
                   "the caller reads result.success — the parsed body must arrive intact (#{path})")
    end
  end

  # --- what the user reads, on each path -------------------------------------

  %w[html_500_sign_in html_500_fallback].each do |path|
    branch = path.end_with?("sign_in") ? "signIn" : "connect + signMessage fallback"

    test "a server verify failure on the #{branch} path names our server" do
      result = outcomes.fetch(path)
      refute result["resolved"], "the helper must reject when the verify answer is unreadable"
      shown = result.fetch("shown")

      assert_match(/server/i, shown, "the user must be told the fault is our server's")
      assert_equal server_copy, shown,
                   "the sentence painted on the page must be the one the layout composes, " \
                   "unchanged by parseSolanaError"
    end

    test "an HTML-bodied 500 on the #{branch} path no longer maps to USDC" do
      shown = outcomes.fetch(path).fetch("shown")

      refute_equal transaction_sentence, shown
      refute_match(/usdc/i, shown, "our outage must not read as the user's wallet being short of funds")
      refute_match(/balance/i, shown, "no balance advice for someone who attempted no transaction")
      refute_match(/transaction/i, shown, "signing in is not a transaction")
    end

    test "the #{branch} path tells a user who already signed that no funds moved" do
      # THE REASON THIS LEG NEEDED ITS OWN SENTENCE rather than the nonce leg's.
      # The signature has ALREADY SUCCEEDED here. A user who just approved a
      # wallet prompt and then met a server fault has every reason to believe
      # something was taken, and the copy has to answer that fear directly.
      shown = outcomes.fetch(path).fetch("shown")
      assert_match(/moves no funds/i, shown,
                   "a user who has already signed must be told the signature moved nothing")
    end
  end

  # --- the substitution is narrow, in TWO directions -------------------------

  test "a network failure keeps its own words and is not relabelled ours" do
    # MUTATION ONE. Wrapping the fetch itself — the obvious simplification, and
    # the one PR 635's third mutant already disproved on the nonce leg — makes a
    # genuinely offline user read our server-fault sentence. Same confidently
    # wrong diagnosis, different innocent party, and every other assertion in
    # this file stays green.
    %w[offline_sign_in offline_fallback].each do |path|
      result = outcomes.fetch(path)
      refute result["resolved"], "an offline verify POST must still reject (#{path})"
      assert_equal "Failed to fetch", result.fetch("shown"),
                   "an offline rejection must reach the surface untouched (#{path})"
      refute_equal server_copy, result.fetch("shown")
    end
  end

  test "a real server rejection still reaches the user in its own words" do
    # MUTATION TWO, and the one this leg adds. docs/AUTH.md used to note that
    # "nothing checks r.ok" as though the check were the fix. It is not.
    # SolanaSessionsController#verify answers 401 and 422 with a JSON body the
    # user MUST read — an expired nonce, a bad signature, the age attestation —
    # and the modal paints `result.error` from it. A throw gated on `!r.ok`
    # would replace all three with the generic server sentence and pass every
    # other test here, because those bodies parse fine.
    %w[rejection_sign_in rejection_fallback].each do |path|
      result = outcomes.fetch(path)
      assert result["resolved"],
             "a NON-2xx answer carrying valid JSON must still resolve so the modal can read " \
             "result.error — gating the substitution on r.ok breaks exactly this (#{path})"
      assert_equal SERVER_REJECTION, result.fetch("result").fetch("error"),
                   "the server's own rejection must arrive verbatim, not replaced by ours (#{path})"
    end
  end

  # --- and it does not manufacture a useless error_logs row ------------------

  test "the substituted server fault is not reported from the browser" do
    # A 500 OF OURS IS ALREADY RECORDED, with its exception and backtrace, by the
    # server that raised it. Reporting it back would file a row carrying our own
    # sentence in BOTH halves — the raw == mapped shape docs/AUTH.md names as an
    # anomaly — and would POST it to the very server that just failed. The tag is
    # what stops the wallet-setup modal's catch from filing it.
    assert outcomes.fetch("html_500_sign_in").fetch("reported"),
           "the substituted error must carry walletFailureReported so no surface files it"
    assert outcomes.fetch("html_500_fallback").fetch("reported")
  end

  test "an offline rejection stays reportable" do
    # The counterweight to the test above: a request that never reached us leaves
    # NO server-side trace, so it is exactly the failure the client reporter
    # exists for. Tagging the whole catch would silence it.
    refute outcomes.fetch("offline_sign_in").fetch("reported"),
           "a network failure must still be reportable by the surface that catches it"
    refute outcomes.fetch("offline_fallback").fetch("reported")
  end

  # --- the coupling the substitution rests on --------------------------------

  test "the verify server sentence survives parseSolanaError untouched" do
    # Substituting only works while the mapper passes unrecognised messages
    # through. Edit the sentence to contain "insufficient funds" and the mapper
    # rewrites it straight back into balance advice — so run the literal the
    # source actually throws past every regex the mapper tests a message against,
    # rather than trusting the one shape driven above.
    mapper = MAPPER.read
    assert_includes mapper, "return msg;", "the pass-through branch is what carries this message"

    mapper.scan(%r{/((?:[^/\\\n]|\\.)+)/([im]*)\.test\(msg\)}).each do |body, flags|
      re = Regexp.new(body, flags.include?("i") ? Regexp::IGNORECASE : 0)
      refute_match re, server_copy,
                   "parseSolanaError would rewrite the verify sentence via /#{body}/#{flags}"
    end
    # The equality branch is not a regex, so the scan above cannot see it.
    refute_equal "Unexpected error", server_copy
  end

  test "the two server sentences are distinct so triage can tell the legs apart" do
    # An operator reading error_logs or a screenshot has to know WHICH fetch
    # failed. Reusing the nonce leg's sentence here would make the two
    # indistinguishable at the only surface that shows either of them.
    nonce_copy = LAYOUT.read[/^\s*var nonceServerCopy = '(.*)';$/, 1]
    refute_nil nonce_copy, "the nonce leg's sentence has moved — see nonce_server_failure_copy_test.rb"
    refute_equal nonce_copy.gsub('\\u2014', "—"), server_copy,
                 "the nonce and verify legs must not read identically to a user or an operator"
  end

  test "the shared transaction wording is left alone for the paths that own it" do
    # The entry flows raise real transaction errors and their copy is correct
    # there. This fix must not have widened its blast radius into the mapper.
    assert_includes MAPPER.read,
                    "Wallet couldn't process the transaction. Check wallet connection and USDC balance.",
                    "the generic transaction branch stays for the entry paths"
  end
end
