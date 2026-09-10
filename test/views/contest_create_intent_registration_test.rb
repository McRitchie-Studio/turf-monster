require "test_helper"
require "open3"
require "json"

# [component] The contest_create / contest_bundle REGISTRATION, executed rather
# than grepped, plus the shape of the three call sites that use them.
#
# THE NAME IS THE WHOLE MECHANISM. On the redirect transport the page is
# destroyed, so the ONLY thing that survives to find these handlers again is the
# string written into the journal. A registration under a different name, or one
# that never runs on the callback document, fails on the RETURN leg — after the
# user has approved in their wallet — which is the worst place to discover it and
# one no desktop test can reach.
class ContestCreateIntentRegistrationTest < ActiveSupport::TestCase
  PARTIAL = Rails.root.join("app/views/shared/_contest_create_intent.html.erb")
  LAYOUT  = Rails.root.join("app/views/layouts/application.html.erb")
  VIEWS = {
    "world cup survivor board" => Rails.root.join("app/views/contests/_world_cup_survivor_board.html.erb"),
    "create contest" => Rails.root.join("app/views/contests/new.html.erb"),
    "contest generator" => Rails.root.join("app/views/contests/generator.html.erb")
  }.freeze

  # PROSE IS NOT CODE, and the counts below must not read it. Every one of these
  # views EXPLAINS what it stopped doing — "before this, the board asked for
  # requireInlineProvider()" — and a scan of the raw file counts that sentence as
  # a live call site. The first version of this test failed on its own comment.
  def code_only(path)
    File.read(path).lines.reject { |line| line.strip.start_with?("//") }.join
  end

  def registration_source
    src = File.read(PARTIAL)
    start = src.index("(function () {\n  var S = window.SolanaStudio;")
    assert start, "could not find the intent registration IIFE in the partial"
    finish = src.index("})();", start)
    assert finish, "could not bound the registration IIFE"
    src[start..(finish + 4)]
  end

  def run_registration(walletops: true)
    studio =
      if walletops
        "window.SolanaStudio = { walletOps: { define: function (n, h) { " \
          "defined.push([n, typeof h.prepare, typeof h.complete, h.signOnly]); } } };"
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

  test "both intents register with both halves and the sign-only declaration" do
    result = run_registration

    assert_equal [["contest_create", "function", "function", true],
                  ["contest_bundle", "function", "function", true]],
                 result["defined"],
                 "each name, both halves, and signOnly — the journal carries the name and the flag, " \
                 "and nothing else can find the handlers again or stop a wallet broadcasting"
    assert_nil result["threw"]
  end

  test "a host without the transport scripts registers nothing and does not throw" do
    # THE ABSENT-CAPABILITY RULE. This partial renders on EVERY page in the app.
    # A page that did not load wallet_ops.js must still work, not die on a missing
    # global before Alpine ever initialises.
    result = run_registration(walletops: false)

    assert_empty result["defined"]
    assert_nil result["threw"], "a missing registry must be a no-op, never an exception"
  end

  test "the layout renders both intents and the runner, so the callback page carries them" do
    # THE FIX THE WHOLE EPIC TURNS ON. Registered from contests/new or
    # contests/generator, these handlers would be absent on /auth/phantom/callback
    # — studio-engine's view, which this app does not override — and
    # walletOps.resume() consumes the journal at take() BEFORE requireHandler
    # runs, so the throw arrives with nothing left to retry.
    src = File.read(LAYOUT)

    assert_includes src, 'render "shared/wallet_op_runner"'
    assert_includes src, 'render "shared/contest_create_intent"'
    assert_operator src.index('render "shared/wallet_op_runner"'),
                    :<,
                    src.index('render "shared/contest_create_intent"'),
                    "the runner defines the fetch and codec helpers the intents call — it must be first"
  end

  # --- the call sites ------------------------------------------------------

  test "each migrated flow has exactly ONE wallet call site" do
    # Asserted on the SOURCE, deliberately and with its limits stated: each call
    # lives inside a submit handler or an Alpine method that cannot be lifted out
    # without its component, and the behaviour is owned by the unit and e2e tiers.
    # What this pins is the COUNT — the whole point of the unification is that a
    # flow no longer carries a redirect branch beside an inline one, and a second
    # call appearing here is that fork growing back.
    VIEWS.each do |label, path|
      src = code_only(path)
      assert_equal 1, src.scan("window.tmWalletOp(").length,
                   "#{label}: one call site, every transport — two is the fork this change removed"
    end
  end

  test "no migrated flow drives a wallet or the chain by hand any more" do
    # THE CONTROL ON THE COUNT ABOVE. A view could satisfy "exactly one
    # tmWalletOp" while still keeping its old inline path beside it, which is
    # precisely what the turf-totals board did before walletOps could serve both
    # transports. These four are the hand-rolled halves that had to go.
    VIEWS.each do |label, path|
      src = code_only(path)
      assert_equal 0, src.scan("provider.signTransaction(").length, "#{label}: signing is walletOps' now"
      assert_equal 0, src.scan("sendRawTransaction").length, "#{label}: the SERVER broadcasts"
      assert_equal 0, src.scan("requireInlineProvider()").length,
                   "#{label}: this flow is taught the redirect transport, so refusing one is a dead end"
      assert_equal 0, src.scan("walletProvider.isAvailable()").length,
                   "#{label}: isAvailable() asks whether a wallet is INJECTED, which is false on every phone"
    end
  end
end
