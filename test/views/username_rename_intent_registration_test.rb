require "test_helper"
require "open3"
require "json"

# [component] The username_rename REGISTRATION, executed rather than grepped.
#
# WHAT THIS TIER OWNS. The unit tests drive the handlers and the call site; this
# one asks the question between them — does the partial actually hand the
# handlers to walletOps under the name the callback page will look up, and does
# it stay out of the way on a page that never loaded the transport?
#
# THE NAME IS THE WHOLE MECHANISM. On the redirect transport the page is
# destroyed, so the only thing that survives to find these handlers again is the
# string "username_rename" written into the journal. A registration under a
# different name, or one that never runs, fails on the RETURN leg — after the
# user has approved a transaction in their wallet, and after resume() consumed
# the journal — which is the worst possible place to discover it and one no
# desktop test can reach.
class UsernameRenameIntentRegistrationTest < ActiveSupport::TestCase
  PARTIAL = Rails.root.join("app/views/shared/_username_rename_intent.html.erb")

  # The registration IIFE, lifted verbatim.
  def registration_source
    src = File.read(PARTIAL)
    start = src.index("(function () {\n  var S = window.SolanaStudio;")
    assert start, "could not find the intent registration IIFE in the partial"
    finish = src.index("})();", start)
    assert finish, "could not bound the registration IIFE"
    src[start..(finish + 4)]
  end

  # `walletops:` true → a real registry is present; false → the page never loaded
  # solana_studio/wallet_ops.js. This partial renders on EVERY page, so the
  # second world is not hypothetical — it is every page served before those
  # script tags, and a throw there would take out the whole document.
  def run_registration(walletops: true)
    studio =
      if walletops
        "window.SolanaStudio = { walletOps: { define: function (n, h) { defined.push([n, typeof h.prepare, typeof h.complete, h.signOnly === undefined ? 'undeclared' : String(h.signOnly)]); } } };"
      else
        "window.SolanaStudio = { };"
      end

    script = <<~JS
      global.window = global;
      var defined = [];
      #{studio}
      var threw = null;
      try { #{registration_source} } catch (e) { threw = e.message; }
      process.stdout.write(JSON.stringify({ defined: defined, threw: threw }));
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, "node failed: #{stderr}"
    JSON.parse(stdout)
  end

  test "the intent registers under the exact name the callback will look up" do
    result = run_registration

    assert_equal 1, result["defined"].length
    name, prepare, complete, _sign_only = result["defined"].first
    assert_equal "username_rename", name,
                 "the journal carries this string and nothing else can find the handlers again"
    assert_equal "function", prepare
    assert_equal "function", complete
    assert_nil result["threw"]
  end

  test "the intent does NOT declare signOnly, and that is deliberate" do
    # A set_username transaction has exactly ONE signer — the user — so the
    # wallet may broadcast it, and on Solflare and Backpack it does. Declaring
    # signOnly would force a co-signing dance with no second signer and give up
    # the faster mobile path for nothing. This is the one place the difference
    # from contest_entry (which MUST declare it) is observable.
    _name, _prepare, _complete, sign_only = run_registration["defined"].first

    assert_equal "undeclared", sign_only,
                 "signOnly belongs to a CO-SIGNED transaction; this one has no second signer"
  end

  test "a page without the transport scripts registers nothing and does not throw" do
    # THE ABSENT-CAPABILITY RULE. This partial renders on every page in the app,
    # including ones served before wallet_ops.js and any page a consumer renders
    # without it. An absent capability must degrade to "no registry", never to an
    # exception thrown out of a layout partial.
    result = run_registration(walletops: false)

    assert_empty result["defined"]
    assert_nil result["threw"]
  end

  test "the finalize URL comes from the route helper, not a hand-typed path" do
    # A literal '/account/confirm_username' would survive a route rename and 404
    # only on the redirect transport — the one nobody tests on a laptop. This is
    # a source assertion because the point IS the source: an executed test would
    # see the rendered string and could not tell which produced it.
    src = File.read(PARTIAL)

    assert_match(/window\.tmUsernameRenameFinalizeUrl = "<%=\s*confirm_username_account_path\s*%>"/, src)
  end
end
