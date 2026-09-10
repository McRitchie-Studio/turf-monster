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
  # The registration IIFE lives in the LAYOUT-rendered partial now — see the
  # note in that file for why the board was the wrong home. The redirect FORK
  # asserted lower down is still the board's, so this file reads both.
  PARTIAL = Rails.root.join("app/views/shared/_contest_entry_intent.html.erb")
  BOARD   = Rails.root.join("app/views/contests/_turf_totals_board.html.erb")

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

  # Brace-match a block opened at `from`, and answer with its body. REGEX WILL
  # NOT DO IT: a non-greedy /.*?\}/ drifts to the first brace that happens to
  # close, so an assertion made against it can hold over a span that is not the
  # branch at all — which is exactly how an earlier version of the `return;`
  # test below passed while the return was deleted. Mutation testing caught it.
  def brace_matched(src, from)
    open_brace = src.index("{", from)
    depth = 0
    finish = nil
    (open_brace...src.length).each do |i|
      case src[i]
      when "{" then depth += 1
      when "}" then (depth -= 1) == 0 && (finish = i)
      end
      break if finish
    end
    assert finish, "could not brace-match the block at #{from}"
    src[open_brace..finish]
  end

  # The post-run transport guard: the `if (isRedirect) { … return; }` that
  # follows the single walletOps.run, not the modal-copy fork that precedes it.
  def post_run_redirect_branch(src)
    run_at = src.index("walletOps.run('contest_entry'")
    assert run_at, "the entry call site moved"
    guard_at = src.index("if (isRedirect) {", run_at)
    assert guard_at, "the redirect guard after the call site is gone — a mobile entry now " \
                     "falls into the inline return leg in a document on its way out"
    brace_matched(src, guard_at)
  end

  # THE HEADLINE PROPERTY OF /tasks/collapse-inline-entry-call-site, and the
  # reason walletOps exists at all: ONE call site for both transports. Until this
  # landed the board ran walletOps for a phone and a hand-rolled copy of the same
  # flow for a laptop — prepare POST, atob, Transaction.from, signTransaction,
  # serialize, chunked btoa, confirm POST — and only the laptop copy was ever
  # exercised, which is how the mobile half rotted unseen in the first place.
  test "contest entry reaches the wallet through exactly one call site" do
    src = File.read(BOARD)

    assert_equal 1, src.scan("walletOps.run(").length,
                 "a second walletOps.run in this board is a second call site by another " \
                 "name — the transports may differ in what the modal says, never in how " \
                 "the transaction is prepared, signed, or posted"

    # The hand-rolled half, named by the calls only it could make. Each of these
    # is now the gem's or the provider's, and finding one here again means the
    # desktop path forked back off on its own.
    { "provider.signTransaction(" => "signing belongs to walletOps, through the intent",
      "solanaWeb3.Transaction.from" => "deserializing belongs to the provider's codec " \
                                       "(INLINE_TX_CODEC in app/javascript/wallet_provider.js)",
      "requireAllSignatures" => "the co-signing serialize options belong to that same codec, " \
                                "in ONE place — a second copy is how one of them gets dropped",
      "/confirm_onchain_entry'" => "posting the signed bytes belongs to the intent's complete()",
      "/prepare_entry'" => "minting the transaction belongs to the intent's prepare()" }
      .each do |fragment, why|
        assert_not_includes src, fragment,
                            "the board still does this itself: #{why}"
      end
  end

  test "the fork asks the provider what it is, never the device" do
    # Asserted on the SOURCE here, deliberately and with its limits stated: the
    # branch lives inside an Alpine method that cannot be lifted out without its
    # component. What this pins is the fork being keyed on the provider's own
    # transport field rather than on a user-agent sniff — the mistake that would
    # send a desktop user inside a wallet's in-app browser down the redirect
    # path, and a phone inside one down a path with no injected wallet. The
    # behaviour is owned by e2e.
    src = File.read(BOARD)

    assert_includes src, "provider.transport === 'redirect'",
                     "the fork must ask the PROVIDER what it is, not guess from the device"
    assert_includes src, "walletOps.run('contest_entry'",
                     "the entry must run the intent by the name registered above"
    refute_match(/isMobile\(\)[^;]*\?[^;]*walletOps\.run/m, src,
                 "transport, not device, decides this fork")
    refute_match(/if\s*\(\s*.*isMobile\(\)\s*\)\s*\{[^}]*walletOps\.run/m, src,
                 "transport, not device, decides this fork")
  end

  test "a wrong wallet keeps the remedy the gem's sentence cannot name" do
    # The CHECK moved to the gem (expectedAccount), and its sentence names both
    # wallets — better than the hand-rolled comparison it replaced. But it can
    # only offer ONE remedy, "switch accounts in your wallet", which is the wrong
    # one for a user whose LINKED address is the stale side. Dropping the Account
    # page from the copy would be a silent regression on exactly that user.
    src = File.read(BOARD)

    assert_includes src, "err.wrongAccount",
                    "the board must recognise the gem's tagged refusal — the message is " \
                    "user-facing prose, so matching on its wording instead would break " \
                    "the moment the gem rewords it"
    assert_includes src, "Or reconnect your wallet on the Account page.",
                    "the second remedy is this app's to offer; the gem does not know " \
                    "where a wallet gets relinked"
  end

  test "the redirect transport returns rather than running the inline return leg" do
    # Without the return, a mobile entry navigates to the wallet AND keeps
    # executing — painting an Entry Confirmed card off a promise that resolved
    # only because the hop had not happened yet, in a document on its way out.
    src = File.read(BOARD)
    branch = post_run_redirect_branch(src)

    # The LAST statement in the block must be the return — not merely present
    # somewhere inside it, which a nested callback could satisfy.
    tail = branch.rstrip.sub(/\}\z/, "").rstrip
    assert tail.end_with?("return;"),
           "the redirect guard must END in `return;` — without it a mobile entry " \
           "navigates to the wallet AND falls into the inline return leg, painting a " \
           "success card for an entry no server has confirmed"
  end

  # --- what the redirect transport owes when the hop does NOT happen ---------
  #
  # ASSERTED ON SOURCE, with the same limits the fork test above states: these
  # live inside an Alpine method that cannot be lifted out without its
  # component. What they pin is that the recovery EXISTS and is keyed on the
  # right signal; the behaviour is owned by e2e. They are here because all three
  # were invisible to every tier when they shipped.

  test "a hop that never happens restores the button and names the failure" do
    src = File.read(BOARD)
    branch = post_run_redirect_branch(src)
    # The listener is ARMED before the call site (it has to be — the hop can take
    # the page during run()) and DISARMED inside the guard after it, so the two
    # halves are asserted at the two places they now live.
    assert_includes src, "window.addEventListener('pagehide', onPageHide",
                    "pagehide firing is the only honest signal that the hop took, and it " \
                    "must be armed before run() — the page can be gone by the time it returns"
    assert_includes branch, "removeEventListener('pagehide', onPageHide)",
                    "an armed listener the guard never disarms leaks into the next attempt"
    assert_includes branch, "board.resetHoldButtons()",
                    "a declined universal link left the hold buttons dead"
    assert_includes branch, "board.submitting = false",
                    "and left submitting true, so a retry was refused"
    assert_match(/sm\.error\(/, branch,
                 "the modal must resolve to something actionable, not spin forever")
  end

  test "the entry flow reports wallet failures like every other wallet path" do
    src = File.read(BOARD)

    assert_includes src, "window.reportWalletFailure('contest_entry'",
                    "this flow logged only through dbg(), a no-op in production — " \
                    "which is why the original mobile crash raised no ErrorLog row, " \
                    "no Sentry event, and no alert, and was found by a user instead"
  end

  test "a blocker payload from the redirect prepare reaches _handleBlockerResponse" do
    src = File.read(BOARD)

    assert_includes src, "err.blockerData && this._handleBlockerResponse(err.blockerData)",
                    "without this every funds/age/first-name/wallet-setup blocker " \
                    "collapsed to raw text on a phone"
  end

  # --- the intent's contract with walletOps ----------------------------------

  # walletOps PREFERS signAndSendTransaction where a wallet offers one
  # (wallet_ops.js:208) and only an intent declaring signOnly opts out. This
  # flow is CO-SIGNED: prepare_entry returns a transaction whose admin slot is
  # empty and the server cosigns and broadcasts, so a wallet that broadcast it
  # would submit a transaction missing a required signature AND leave the server
  # without the bytes it must cosign. The partial documented that in prose for a
  # lap while the flag was absent; prose does not reach the gem.
  test "the intent declares signOnly so a co-signed entry is never broadcast" do
    src = File.read(PARTIAL)
    start = src.index("S.walletOps.define('contest_entry', {")
    assert start, "the intent registration moved"
    # Bounded at the first handler key, so the flag has to sit ON this intent
    # rather than anywhere later in the file.
    finish = src.index("prepare: function", start)
    assert finish && finish > start, "could not bound the intent's option block"

    assert_includes src[start...finish], "signOnly: true",
                    "without this the gem takes signAndSendTransaction wherever a wallet " \
                    "offers it, and the server never receives bytes to cosign"
  end
end
