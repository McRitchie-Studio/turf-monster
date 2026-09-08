require "test_helper"
require "open3"
require "json"

# [component] The intent REGISTRATION, executed rather than grepped.
#
# WHAT THIS TIER OWNS. The unit test drives the two handlers; this one asks the
# question one layer up — does the partial actually hand them to walletOps under
# the name the callback page will look up, and does it stay out of the way when
# the transport scripts are absent?
#
# THE NAME IS THE WHOLE MECHANISM. On the redirect transport the page is
# destroyed, so the ONLY thing that survives to find these handlers again is the
# string "contest_entry" written into the journal. A registration under a
# different name, or one that never runs, fails on the RETURN leg — after the
# user has approved a transaction in their wallet — which is the worst possible
# place to discover it and one no desktop test can reach.
class ContestEntryIntentRegistrationTest < ActiveSupport::TestCase
  PARTIAL = Rails.root.join("app/views/contests/_turf_totals_board.html.erb")

  # The registration IIFE, lifted verbatim.
  def registration_source
    src = File.read(PARTIAL)
    start = src.index("(function () {\n  var S = window.SolanaStudio;")
    assert start, "could not find the intent registration IIFE in the partial"
    finish = src.index("})();", start)
    assert finish, "could not bound the registration IIFE"
    src[start..(finish + 4)]
  end

  # `walletops:` true → a real registry is present; false → the host never loaded
  # solana_studio/wallet_ops.js, which is every consumer that has not adopted it.
  def run_registration(walletops: true)
    studio =
      if walletops
        "window.SolanaStudio = { walletOps: { define: function (n, h) { defined.push([n, typeof h.prepare, typeof h.complete]); } } };"
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

    assert_equal [["contest_entry", "function", "function"]], result["defined"],
                 "both halves must be registered under 'contest_entry' — the journal " \
                 "carries that string and nothing else can find them again"
    assert_nil result["threw"]
  end

  test "a host without the transport scripts registers nothing and does not throw" do
    # THE ABSENT-CAPABILITY RULE. This partial renders on every contest page. A
    # consumer that has not loaded wallet_ops.js must get a working desktop board,
    # not a page that died on a missing global before Alpine ever initialised.
    result = run_registration(walletops: false)

    assert_empty result["defined"]
    assert_nil result["threw"], "a missing registry must be a no-op, never an exception"
  end

  test "the redirect branch forks on transport and leaves the inline path alone" do
    # Asserted on the SOURCE here, deliberately and with its limits stated: the
    # branch lives inside an Alpine method that cannot be lifted out without its
    # component. What this pins is the FORK EXISTING and being keyed on the
    # provider's own transport field rather than on a user-agent sniff — which is
    # the mistake that would send a desktop user inside a wallet's in-app browser
    # down the redirect path. The behaviour is owned by e2e.
    src = File.read(PARTIAL)

    assert_includes src, "provider.transport === 'redirect'",
                     "the fork must ask the PROVIDER what it is, not guess from the device"
    assert_includes src, "walletOps.run('contest_entry'",
                     "the redirect branch must run the intent by the name registered above"
    refute_match(/if\s*\(\s*.*isMobile\(\)\s*\)\s*\{[^}]*walletOps\.run/m, src,
                 "transport, not device, decides this fork")
  end

  test "the redirect branch returns rather than falling into the inline path" do
    # Without the return, a mobile entry would navigate to the wallet AND keep
    # executing the inline flow in a document that is on its way out — a second
    # prepare_entry, a second prepared-transaction row, and a race nobody can see.
    # BRACE-MATCHED, not regex-matched. A non-greedy /.*?\}/ drifts to the first
    # brace that happens to close, and then finds SOME later `return;` inside a
    # span that is not the branch — which is exactly how the first version of
    # this test passed while the return was deleted. Mutation testing caught it.
    src = File.read(PARTIAL)
    start = src.index("if (provider.transport === 'redirect') {")
    assert start, "could not find the redirect branch"

    open_brace = src.index("{", start)
    depth = 0
    finish = nil
    (open_brace...src.length).each do |i|
      case src[i]
      when "{" then depth += 1
      when "}" then (depth -= 1) == 0 && (finish = i)
      end
      break if finish
    end
    assert finish, "could not brace-match the redirect branch"
    branch = src[open_brace..finish]

    # The LAST statement in the block must be the return — not merely present
    # somewhere inside it, which a nested callback could satisfy.
    tail = branch.rstrip.sub(/\}\z/, "").rstrip
    assert tail.end_with?("return;"),
           "the redirect branch must END in `return;` — without it a mobile entry " \
           "navigates to the wallet AND keeps running the inline flow in a document " \
           "on its way out, minting a second prepared-transaction row nobody can see"
  end
end
