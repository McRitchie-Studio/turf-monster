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
  # note in that file for why the board was the wrong home. The transport FORK
  # and the handoff watch moved out of the board too, into the runner
  # (/tasks/route-board-through-runner), so this file reads all three: what the
  # board still owns, and where the halves it gave up now live.
  PARTIAL = Rails.root.join("app/views/shared/_contest_entry_intent.html.erb")
  BOARD   = Rails.root.join("app/views/contests/_turf_totals_board.html.erb")
  RUNNER  = Rails.root.join("app/views/shared/_wallet_op_runner.html.erb")

  # The board's code with its full-line comments removed. The board's comments
  # NAME the things it no longer does — redirectLink, pagehide, walletOps.run —
  # so an absence asserted over prose would fail on the explanation of why the
  # code is gone. Only full-line comments go: a trailing comment stays, which can
  # make a refutation stricter but never vacuous.
  def board_code
    File.read(BOARD).lines.reject { |l| l =~ %r{\A\s*//} }.join
  end

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

  # The board's ONE wallet call, from `window.tmWalletOp(` to its closing paren,
  # paren-matched for the same reason brace_matched exists: the call spans an
  # options object with a nested function, and a regex drifts to the first `)`.
  def board_call(src)
    call_at = src.index("window.tmWalletOp('contest_entry'")
    assert call_at, "the board's entry call moved or stopped using the runner"
    open_paren = src.index("(", call_at)
    depth = 0
    finish = nil
    (open_paren...src.length).each do |i|
      case src[i]
      when "(" then depth += 1
      when ")" then (depth -= 1) == 0 && (finish = i)
      end
      break if finish
    end
    assert finish, "could not paren-match the board's tmWalletOp call"
    [call_at, finish]
  end

  # THE HEADLINE PROPERTY OF /tasks/collapse-inline-entry-call-site, and the
  # reason walletOps exists at all: ONE call site for both transports. Until that
  # landed the board ran walletOps for a phone and a hand-rolled copy of the same
  # flow for a laptop — prepare POST, atob, Transaction.from, signTransaction,
  # serialize, chunked btoa, confirm POST — and only the laptop copy was ever
  # exercised, which is how the mobile half rotted unseen in the first place.
  #
  # WHAT IT PINS NOW (/tasks/route-board-through-runner). It used to count ONE
  # walletOps.run in the board. That call moved into the runner, so the board
  # holds exactly one window.tmWalletOp and NO walletOps.run: a direct run
  # reappearing here is a second call site, and one that would carry its own
  # address book again — the defect that lost an approved entry on QA.
  test "contest entry reaches the wallet through exactly one call site" do
    src = File.read(BOARD)
    code = board_code

    assert_equal 1, code.scan("window.tmWalletOp(").length,
                 "a second tmWalletOp in this board is a second call site by another " \
                 "name — the transports may differ in what the modal says, never in how " \
                 "the transaction is prepared, signed, or posted"
    assert_equal 0, code.scan("walletOps.run(").length,
                 "the board calls walletOps.run directly again — that call site must spell " \
                 "out its own redirectLink, and a missing one lost a real user's entry"

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
    # Asserted on the SOURCE here, deliberately and with its limits stated.
    # What this pins is the fork being keyed on the provider's own transport
    # field rather than on a user-agent sniff — the mistake that would send a
    # desktop user inside a wallet's in-app browser down the redirect path, and a
    # phone inside one down a path with no injected wallet. The behaviour is
    # owned by e2e and by test/lib/board_entry_call_site_js_test.rb.
    #
    # WHAT IT PINS NOW. The fork used to be the board's own `isRedirect`. It
    # moved into the runner, which every contest flow shares, so the provider
    # question is asserted THERE — and the board is asserted to ask no transport
    # question of its own, which is what keeps the fork decided in one place.
    runner = File.read(RUNNER)
    code = board_code

    assert_includes runner, "provider.transport === 'redirect'",
                    "the fork must ask the PROVIDER what it is, not guess from the device"
    assert_includes code, "window.tmWalletOp('contest_entry'",
                    "the entry must run the intent by the name registered above, through the runner"
    %w[provider.transport requireProvider isRedirect].each do |fork|
      assert_not_includes code, fork,
                          "the board forks on transport again (#{fork}) — a second copy of a " \
                          "decision the runner makes for every contest flow"
    end
    refute_match(/isMobile\(\)[^;]*\?[^;]*tmWalletOp/m, code,
                 "transport, not device, decides this fork")
    refute_match(/if\s*\(\s*.*isMobile\(\)\s*\)\s*\{[^}]*tmWalletOp/m, code,
                 "transport, not device, decides this fork")
  end

  # ACCEPTANCE, stated as an absence the board could regrow. The four things
  # the runner exists to write once — the return address, the app identity, the
  # cluster, and the handoff watch — must not be written again here. The runner
  # is asserted to hold them, so an absence here is a move, never a loss.
  test "the board writes none of the redirect address book; the runner holds all of it" do
    runner = File.read(RUNNER)
    code = board_code

    { "redirectLink" => "the return address",
      "/auth/phantom/callback" => "the callback route the return address names",
      "appUrl" => "the app identity",
      "solanaCluster" => "the cluster",
      "'pagehide'" => "the handoff watch" }.each do |token, what|
      assert_not_includes code, token,
                          "the board spells out #{what} again — the same address book written " \
                          "twice, which is how a hand-rolled site came to omit one"
      assert_includes runner, token, "the runner no longer holds #{what}"
    end
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
    #
    # WHAT IT PINS NOW. The guard used to be `if (isRedirect) { … return; }`
    # keyed on the board's own fork. The board has no fork any more, so it reads
    # what the runner hands back instead: runRedirect resolves
    # `{ suspended: true }` once it has navigated, and the survivor board already
    # guards on exactly that. Pinned as the FIRST statement after the call, not
    # merely present somewhere later — anything between the two would run on the
    # redirect transport too. The behaviour is driven in
    # test/lib/board_entry_call_site_js_test.rb.
    code = board_code
    _, call_end = board_call(code)
    after_call = code[(call_end + 1)..].sub(/\A\s*;/, "")

    assert_equal "if (!confirmData || confirmData.suspended) return;", after_call.lstrip.lines.first.strip,
                 "the statement after the runner call must end the redirect transport — " \
                 "without it a mobile entry navigates to the wallet AND falls into the " \
                 "inline return leg, painting a success card for an entry no server has confirmed"
  end

  # --- what the redirect transport owes when the hop does NOT happen ---------
  #
  # ASSERTED ON SOURCE, with the same limits the fork test above states. What
  # they pin is that the recovery EXISTS and is keyed on the right signal; the
  # behaviour is driven in test/lib/board_entry_call_site_js_test.rb and in
  # test/lib/wallet_op_runner_js_test.rb. They are here because all three were
  # invisible to every tier when they shipped.

  test "a hop that never happens restores the button and names the failure" do
    # WHAT IT PINS NOW. This used to find the pagehide listener, its removal,
    # the error card and the button reset all inside the board's own redirect
    # branch. The watch moved into the runner — ONE copy, which is what lets a
    # later fix to it (a pageshow answer for a restored page) cover this board
    # without touching it. So the halves are asserted where they now live: the
    # watch and the card in the runner, and in the board only what the runner
    # cannot know — that this board's hold buttons are dead and it is still
    # marked submitting.
    runner = File.read(RUNNER)
    assert_includes runner, "window.addEventListener('pagehide', onPageHide",
                    "pagehide firing is the only honest signal that the hop took, and it " \
                    "must be armed before run() — the page can be gone by the time it returns"
    assert_includes runner, "window.removeEventListener('pagehide', onPageHide)",
                    "an armed listener the watch never disarms leaks into the next attempt"
    assert_includes runner, "'Wallet Did Not Open'",
                    "the modal must resolve to something actionable, not spin forever"

    code = board_code
    call_start, call_end = board_call(code)
    call = code[call_start..call_end]
    stranded_at = call.index("onStranded: function () {")
    assert stranded_at, "the board no longer tells the runner what to undo when the hop " \
                        "never happens — the runner paints the card but the board stays stuck"
    stranded = brace_matched(call, stranded_at)
    assert_includes stranded, "board.resetHoldButtons()",
                    "a declined universal link left the hold buttons dead"
    assert_includes stranded, "board.submitting = false",
                    "and left submitting true, so a retry was refused"
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
