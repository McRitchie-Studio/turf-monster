require "test_helper"
require "open3"
require "json"

# [component] What the PARTIAL EMITS, executed — not what the file contains.
#
# WHY THIS TIER IS NOT A DUPLICATE of the unit test one layer down. That test
# lifts a block out of the file by string index and drives it. It therefore proves
# that block's logic and nothing about the view: an ERB comment that swallows the
# script, a stray `<%` that eats it, a partial moved out of the layout's reach —
# each leaves the unit test perfectly green while the browser receives nothing.
# This app has a guard for exactly that class already
# (test/lib/erb_comment_percent_test.rb), which is why the question is worth
# asking here too, against the real render.
#
# THIS FILE WAS contest_entry_intent_resume_wrapper_test.rb UNTIL 2026-09-20.
# It drove a turf-side `walletOps.resume` wrapper that defaulted the signing hop's
# `redirect_link`; solana-studio journals `redirectLink` in `beginConnect` from
# 0.9.3, the Gemfile floor is now `>= 0.12.0`, and
# /tasks/retire-wallet-resume-wrapper deleted the wrapper. What this tier was
# ALWAYS really asking survives and is now what it asserts: that the script this
# partial emits parses, RUNS, and registers the contest_entry intent with its
# handlers attached. That is the property whose loss cost a real approved entry.
#
# So this renders the partial through the real view stack and runs WHAT CAME OUT.
class ContestEntryIntentRenderedScriptTest < ActionView::TestCase
  # Everything between the script tags the partial emits.
  def rendered_script
    html = ApplicationController.render(partial: "shared/contest_entry_intent")
    scripts = html.scan(%r{<script[^>]*>(.*?)</script>}m).flatten
    assert scripts.any?, "the partial rendered no script at all"
    scripts.join("\n")
  end

  # Runs the emitted script in node against a walletOps stub that records what
  # was registered, and reports what the document ended up carrying.
  def run_emitted_script
    script = <<~JS
      global.window = global;
      window.location = { origin: "https://turf.test", pathname: "/auth/phantom/callback" };
      var registered = {};
      var resumeReplaced = false;
      var originalResume = function (params, opts) { return Promise.resolve('inner'); };
      window.SolanaStudio = {
        walletOps: {
          define: function (name, handlers) { registered[name] = handlers; },
          // The production call, verbatim from studio-engine's
          // solana_sessions/phantom_callback.html.erb — `{ navigate }` and
          // nothing else. Kept so this tier still SEES a partial that starts
          // wrapping it again.
          resume: originalResume
        }
      };
      // The partial's other half calls document/console at definition time only,
      // so a bare shim is enough to let the whole emitted script parse and run.
      window.document = { getElementById: function () { return null; } };
      console.log = function () {};
      #{rendered_script}
      resumeReplaced = window.SolanaStudio.walletOps.resume !== originalResume;
      process.stdout.write(JSON.stringify({
        intents: Object.keys(registered),
        prepare: registered.contest_entry && typeof registered.contest_entry.prepare,
        complete: registered.contest_entry && typeof registered.contest_entry.complete,
        signOnly: registered.contest_entry && registered.contest_entry.signOnly,
        tmPrepare: typeof window.tmPrepareContestEntry,
        tmComplete: typeof window.tmCompleteContestEntry,
        resumeReplaced: resumeReplaced
      }));
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, "the partial's own output failed to run in node: #{stderr}"
    JSON.parse(stdout)
  end

  test "the rendered partial registers the contest_entry intent with its handlers" do
    result = run_emitted_script

    assert_includes result["intents"], "contest_entry",
                    "the emitted script registered no contest_entry intent. walletOps.resume consumes " \
                    "the journal before requireHandler, so a callback document without this " \
                    "registration loses the entry after the user has already approved it"
    assert_equal "function", result["prepare"], "the registered intent has no prepare handler"
    assert_equal "function", result["complete"], "the registered intent has no complete handler"

    # SIGN-ONLY IS A REQUIREMENT, not a preference: prepare_entry returns a
    # partially signed transaction whose admin slot is empty, and a wallet that
    # broadcast it would hand Solana a transaction missing a signature — and we
    # would never receive the bytes the server must cosign. walletOps otherwise
    # PREFERS signAndSendTransaction where a wallet has one.
    assert_equal true, result["signOnly"],
                 "the registered intent no longer declares signOnly, so walletOps may prefer " \
                 "signAndSendTransaction and the server never receives the bytes it must cosign"

    # The handlers the registration POINTS AT must reach the same document.
    assert_equal "function", result["tmPrepare"], "the emitted script does not define tmPrepareContestEntry"
    assert_equal "function", result["tmComplete"], "the emitted script does not define tmCompleteContestEntry"
  end

  test "the rendered partial leaves walletOps.resume alone" do
    # THE RETIREMENT, ASSERTED WHERE IT CAN BE OBSERVED RATHER THAN GREPPED.
    # Until 2026-09-20 this partial replaced `walletOps.resume` to default the
    # signing hop's `redirect_link`, because neither studio-engine nor
    # solana-studio supplied one. The gem journals it in `beginConnect` from
    # 0.9.3 and the Gemfile floors at `>= 0.12.0`, so the default is retired and
    # the gem owns that parameter alone. A host-side wrapper creeping back is not
    # harmless bloat: it silently re-answers a question the gem now answers, and
    # the next reader cannot tell which side supplied the value. §7 of
    # docs/WALLET_TRANSPORT_ARCHITECTURE.md carries the record, and the §7 test in
    # test/docs/workflow_citation_docs_test.rb holds the document to it.
    assert_equal false, run_emitted_script["resumeReplaced"],
                 "the emitted script replaced SolanaStudio.walletOps.resume. The turf-side " \
                 "redirect_link default was retired at solana-studio >= 0.12.0 — if a host default " \
                 "is needed again, say so in §7 of docs/WALLET_TRANSPORT_ARCHITECTURE.md, which " \
                 "states the gem carries this alone"
  end

  test "the layout renders this partial on every document" do
    # THE PLACEMENT IS THE MECHANISM. The registration only helps on the page a
    # wallet RETURNS to, and that page is studio-engine's — this app ships no
    # override. Rendering the partial from the board instead of the layout is the
    # exact mistake that lost an approved entry once already; see the partial's
    # header.
    layout = File.read(Rails.root.join("app/views/layouts/application.html.erb"))

    assert_includes layout, 'render "shared/contest_entry_intent"',
                    "the intent partial must be rendered by the LAYOUT, not by a page-specific view"

    # …and AFTER the gem script it registers against. Order is not cosmetic: the
    # partial reads SolanaStudio.walletOps at parse time and returns early when it
    # is absent, so a blocking tag that comes later leaves nothing to register on
    # — silently.
    ops_at = layout.index("solana_studio/wallet_ops")
    partial_at = layout.index('render "shared/contest_entry_intent"')
    assert ops_at, "the layout no longer loads solana_studio/wallet_ops.js"
    assert ops_at < partial_at,
           "wallet_ops.js must be included BEFORE the intent partial, or walletOps.define is absent " \
           "and the partial's own guard returns early, registering nothing"
  end
end
