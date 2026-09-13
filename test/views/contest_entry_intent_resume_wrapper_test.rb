require "test_helper"
require "open3"
require "json"

# [component] What the PARTIAL EMITS, executed — not what the file contains.
#
# WHY THIS TIER IS NOT A DUPLICATE of the unit test one layer down. That test
# lifts the registration IIFE out of the file by string index and drives it. It
# therefore proves the WRAPPER's logic and nothing about the view: an ERB comment
# that swallows the block, a stray `<%` that eats the script, a partial moved out
# of the layout's reach — each leaves that test perfectly green while the browser
# receives nothing. This app has a guard for exactly that class already
# (test/lib/erb_comment_percent_test.rb), which is why the question is worth
# asking here.
#
# So this renders the partial through the real view stack and runs WHAT CAME OUT.
class ContestEntryIntentResumeWrapperTest < ActionView::TestCase
  # Everything between the script tags the partial emits.
  def rendered_script
    html = ApplicationController.render(partial: "shared/contest_entry_intent")
    scripts = html.scan(%r{<script[^>]*>(.*?)</script>}m).flatten
    assert scripts.any?, "the partial rendered no script at all"
    scripts.join("\n")
  end

  test "the rendered partial installs a resume that defaults redirect_link" do
    script = <<~JS
      global.window = global;
      window.location = { origin: "https://turf.test", pathname: "/auth/phantom/callback" };
      var seenOpts = null;
      window.SolanaStudio = {
        walletOps: {
          define: function () {},
          // The production call, verbatim from studio-engine 0.74.6's
          // solana_sessions/phantom_callback.html.erb — `{ navigate }` and
          // nothing else.
          resume: function (params, opts) { seenOpts = opts; return Promise.resolve('inner'); }
        }
      };
      // The partial's OTHER half calls document/console at definition time only,
      // so a bare shim is enough to let the whole emitted script parse and run.
      window.document = { getElementById: function () { return null; } };
      console.log = function () {};
      #{rendered_script}
      window.SolanaStudio.walletOps.resume({ nonce: 'N' }, { navigate: function () {} }).then(function () {
        process.stdout.write(JSON.stringify({
          redirectLink: seenOpts && seenOpts.redirectLink,
          registered: typeof window.tmCompleteContestEntry
        }));
      });
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, "the partial's own output failed to run in node: #{stderr}"
    result = JSON.parse(stdout)

    assert_equal "https://turf.test/auth/phantom/callback", result["redirectLink"],
                 "the signing hop's deeplink omits redirect_link without this"
    assert_equal "function", result["registered"],
                 "the same script must still ship the handlers — the wrapper is an addition, not a replacement"
  end

  test "the layout renders this partial on every document" do
    # THE PLACEMENT IS THE MECHANISM. The wrapper only helps on the page a wallet
    # RETURNS to, and that page is studio-engine's — this app ships no override.
    # Rendering the partial from the board instead of the layout is the exact
    # mistake that lost an approved entry once already; see the partial's header.
    layout = File.read(Rails.root.join("app/views/layouts/application.html.erb"))

    assert_includes layout, 'render "shared/contest_entry_intent"',
                    "the intent partial must be rendered by the LAYOUT, not by a page-specific view"

    # …and AFTER the gem script it patches. Order is not cosmetic: the wrapper
    # reads SolanaStudio.walletOps.resume at parse time, and a blocking tag that
    # comes later leaves nothing to wrap.
    ops_at = layout.index("solana_studio/wallet_ops")
    partial_at = layout.index('render "shared/contest_entry_intent"')
    assert ops_at, "the layout no longer loads solana_studio/wallet_ops.js"
    assert ops_at < partial_at,
           "wallet_ops.js must be included BEFORE the intent partial, or there is no resume to wrap"
  end
end
