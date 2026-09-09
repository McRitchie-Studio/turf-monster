require "test_helper"
require "json"
require "open3"

# [component] What a NONCE-endpoint failure of OURS says to a paying user.
#
# THE DEFECT, MEASURED. `/auth/solana/nonce` answers with an HTML body — see
# WHICH FAULTS below — so `r.json()` rejects with V8's
# "Unexpected token '<', \"<!DOCTYPE \"... is not valid JSON".
# `parseSolanaError`'s generic branch matches /^unexpected/i and answers "Wallet
# couldn't process the transaction. Check wallet connection and USDC balance."
# An outage of OURS, read back to a signed-out user as their wallet being short
# of funds — the worst direction the mistake can point on a money page.
#
# WHICH FAULTS SEND AN UNREADABLE BODY. Not "any unhandled exception", which is
# what this file claimed until 2026-09-09. The identical sentence stood in
# test/views/verify_server_failure_copy_test.rb and both are corrected together:
# leaving one standing is how this house ends up with two authorities on the same
# fact. `#nonce` has no local rescue, so an exception inside it reaches the
# ENGINE CATCH-ALL — `Studio::ErrorHandling` registers `rescue_from StandardError`
# — whose production branch `respond_to`s. This fetch sends no Accept header, so
# it takes `format.html`: a 302 to root, which `fetch` FOLLOWS to an HTML body at
# STATUS 200. A fault outside `rescue_from`'s reach (middleware, routing) is the
# one that renders a true 500 page.
#
# EITHER WAY THE BODY IS HTML AND `r.json()` REJECTS, which is all this guard
# needs — but the status is NOT reliably 500, and the fixture below drives the
# body rather than the status for exactly that reason.
#
# READ WHAT THE USER READS, NOT WHICH BRANCH RAN. A test asserting that a guard
# exists, or that a tag was set, passes on a page that still prints the balance
# sentence — the string only becomes wrong after the mapper runs, and the mapper
# runs at the SURFACE. So this file lifts the helper out of the RENDERED page,
# executes it in Node against a real 500 Response with an HTML body, maps the
# rejection exactly the way modals/_wallet_setup.html.erb does, and asserts the
# decoded sentence a human would be looking at.
#
# BOTH WALLET PATHS, BECAUSE ONLY ONE OF THEM HAS A GUARD. The signIn branch
# awaits the nonce ABOVE its try — the nonce is an INPUT to signIn — so its
# rejection is caught by nothing in the helper and lands on the surface intact.
# Phantom supports signIn. A fix at the `nonceFetchFailed` guard alone would
# have left the commonest wallet reading the balance advice, and every
# source-level assertion about that guard would have stayed green.
class NonceServerFailureCopyTest < ActionDispatch::IntegrationTest
  LAYOUT = Rails.root.join("app/views/layouts/application.html.erb")
  MAPPER = Rails.root.join("app/javascript/solana_errors.js")

  # What Rails actually sends when an exception escapes: a rendered page. The
  # doctype is the whole discriminator — a JSON-bodied 500 parses fine and fails
  # later, somewhere else, saying something else.
  HTML_500 = "<!DOCTYPE html>\n<html><body><h1>We're sorry, but something went wrong.</h1></body></html>".freeze

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
      line = LAYOUT.read[/^\s*var nonceServerCopy = '(.*)';$/, 1]
      refute_nil line, "the server sentence must be composed once, as a one-line literal"
      line.gsub('\\u2014', "—")
    end
  end

  # The helper as the BROWSER receives it, lifted from the rendered page by
  # brace matching. Reading the .erb source instead would pass over a layout that
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

  # Drive the real helper against a real Response. `r.json()` rejects here for
  # the same reason and in the same engine as it does in Chrome, so the raw
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
        // WHICH WALLET METHODS THE HELPER ACTUALLY REACHED, for the drive in
        // flight. Reset per drive. On this leg the record is not bookkeeping —
        // it is the file's central structural claim, made checkable: see the
        // "no wallet prompt is opened" test below.
        var calls = [];

        function provider(supportsSignIn) {
          return {
            name: 'phantom',
            supportsSignIn: function () { return supportsSignIn; },
            signIn: async function () {
              calls.push('signIn');
              throw new Error('signIn should not be reached');
            },
            connect: async function () {
              calls.push('connect');
              return { publicKey: { toBase58: function () { return 'PubKeyBase58'; } } };
            },
            signMessage: async function () {
              calls.push('signMessage');
              return { signature: new Uint8Array(64) };
            }
          };
        }

        async function drive(shape, supportsSignIn) {
          calls = [];
          globalThis.fetch = shape;
          window.walletProvider = {
            get: function () { return provider(supportsSignIn); },
            detect: function () { return provider(supportsSignIn); }
          };
          try {
            await window.solanaConnectAndVerify('phantom', {});
            return { resolved: true, calls: calls };
          } catch (e) {
            // modals/_wallet_setup.html.erb, verbatim: the wallet's string, then
            // the mapper, then onto the page as `this.error`.
            var raw = (e && e.message) || '';
            var shown = (e && e.code === 4001) ? 'Signature rejected' : (raw || 'Connection failed');
            shown = window.parseSolanaError(shown);
            return { raw: raw, shown: shown, reported: !!(e && e.walletFailureReported), calls: calls };
          }
        }

        var html = async function () {
          return new Response(HTML, { status: 500, headers: { 'Content-Type': 'text/html' } });
        };
        var offline = async function () { throw new TypeError('Failed to fetch'); };

        // THE CONTROL, run in the same engine on the same body: what r.json()
        // ACTUALLY rejects with, and what the mapper still does with it.
        var parseRejection = null;
        try {
          await new Response(HTML, { status: 500 }).json();
        } catch (e) {
          parseRejection = e.message;
        }

        console.log(JSON.stringify({
          html_sign_in: await drive(html, true),
          html_fallback: await drive(html, false),
          offline_sign_in: await drive(offline, true),
          offline_fallback: await drive(offline, false),
          parse_rejection: parseRejection,
          control_mapped: window.parseSolanaError(parseRejection)
        }));
      JS

      stdout, stderr, status = Open3.capture3("node", "--input-type=module", "--eval", script)
      assert status.success?, stderr
      JSON.parse(stdout.lines.map(&:strip).reject(&:empty?).last)
    end
  end

  # --- each path's rows really were collected from that path -----------------

  test "the signIn path opens no wallet prompt at all, and the fallback opens one" do
    # FINDING 1's TWIN, 2026-09-09. The header above argues from a STRUCTURAL
    # fact: the signIn branch awaits the nonce ABOVE its `try`, because the nonce
    # is an INPUT to `signIn()`, so a nonce failure is caught by nothing in the
    # helper. Nothing here checked that. Forcing `useSignIn` either way in the
    # layout left every assertion green, because both paths end in the same
    # rejection carrying the same sentence — identical outcomes cannot tell two
    # branches apart, and a claim of coverage no assertion backs is worse than
    # silence: it stops the next reader adding the test.
    #
    # WHAT THE RECORD PROVES, and why it is not bookkeeping. On the signIn path
    # the wallet is never touched — the nonce rejects before `provider.signIn`
    # is reached — so the user is refused BEFORE a prompt opens. On the fallback
    # `connect()` has already run and the human has already approved something.
    # That asymmetry IS the argument for substituting inside `r.json()` rather
    # than at the `nonceFetchFailed` guard, which only the fallback reaches.
    #
    # IT DOES NOT REPLACE READING THE SENTENCE. A branch check passes on a page
    # that still prints the balance advice. This is the floor under the decoded
    # copy assertions below: it proves each was collected from the path its name
    # claims.
    %w[html offline].each do |shape|
      assert_equal [], outcomes.fetch("#{shape}_sign_in").fetch("calls"),
                   "a signIn-capable wallet must never be prompted when the nonce fails (#{shape}) — " \
                   "a wallet call here means the helper took the fallback and the #{shape}_sign_in " \
                   "row describes the wrong path"
      assert_equal %w[connect], outcomes.fetch("#{shape}_fallback").fetch("calls"),
                   "the fallback must connect BEFORE it awaits the nonce (#{shape}) — that ordering " \
                   "is what buys the overlap the helper's comments claim, and an empty record here " \
                   "means the await was hoisted back above connect()"
    end
  end

  # --- the control: the shape is real and the mapper still mis-maps it --------

  test "an HTML-bodied 500 really does reject the way the mapper mis-reads" do
    # WITHOUT THIS, EVERY GREEN BELOW IS UNFALSIFIABLE. If the body stopped
    # producing the /^unexpected/i shape — a different doctype, a changed engine
    # message — the tests below would pass while proving nothing, because the
    # defect would no longer be reachable through the fixture.
    assert_match(/\AUnexpected token '<'/, outcomes.fetch("parse_rejection"),
                 "the HTML body must still make r.json() reject with the string the mapper matches")
    assert_equal transaction_sentence, outcomes.fetch("control_mapped"),
                 "the mapper must still rewrite that raw string into balance advice — " \
                 "this is the mis-mapping the substitution exists to get in front of"
  end

  # --- what the user reads, on each path -------------------------------------

  %w[html_sign_in html_fallback].each do |path|
    branch = path == "html_sign_in" ? "signIn" : "connect + signMessage fallback"

    test "a server nonce failure on the #{branch} path names our server" do
      result = outcomes.fetch(path)
      refute result["resolved"], "the helper must still reject when it cannot get a nonce"
      shown = result.fetch("shown")

      assert_match(/server/i, shown,
                   "the user must be told the fault is our server's")
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
  end

  # --- the substitution is narrow: an offline user is not told it was us ------

  test "a network failure keeps its own words and is not relabelled ours" do
    # THE MUTATION THIS CATCHES. Moving the substitution up into the single
    # .catch — the obvious simplification — makes every nonce failure read as a
    # server fault of ours, including the one where the request never reached us.
    # That is the same confidently-wrong diagnosis, pointed at a different
    # innocent party, and every other assertion in this file stays green.
    %w[offline_sign_in offline_fallback].each do |path|
      result = outcomes.fetch(path)
      assert_equal "Failed to fetch", result.fetch("shown"),
                   "an offline rejection must reach the surface untouched (#{path})"
      refute_equal server_copy, result.fetch("shown")
    end
  end

  # --- and it does not manufacture a useless error_logs row ------------------

  test "the substituted server fault is not reported from the browser" do
    # A 500 OF OURS IS ALREADY RECORDED, with its exception and backtrace, by the
    # server that raised it. Reporting it back would file a row carrying our own
    # sentence in BOTH halves — the raw == mapped shape docs/AUTH.md names as an
    # anomaly — and would POST it to the very server that just failed. The tag is
    # what stops the wallet-setup modal's catch from filing it.
    assert outcomes.fetch("html_sign_in").fetch("reported"),
           "the substituted error must carry walletFailureReported so no surface files it"
    assert outcomes.fetch("html_fallback").fetch("reported")
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

  test "the server sentence survives parseSolanaError untouched" do
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
                   "parseSolanaError would rewrite the server sentence via /#{body}/#{flags}"
    end
    # The equality branch is not a regex, so the scan above cannot see it.
    refute_equal "Unexpected error", server_copy
  end

  test "the shared transaction wording is left alone for the paths that own it" do
    # The entry flows raise real transaction errors and their copy is correct
    # there. This fix must not have widened its blast radius into the mapper.
    assert_includes MAPPER.read,
                    "Wallet couldn't process the transaction. Check wallet connection and USDC balance.",
                    "the generic transaction branch stays for the entry paths"
  end
end
