require "test_helper"
require "open3"
require "json"

# [unit] contests/_turf_totals_board#confirmEntry — the board's on-chain entry,
# EXECUTED through the real window.tmWalletOp on both transports.
#
# WHAT THIS TIER OWNS. wallet_op_runner_js_test drives the runner with a caller
# it invents. This drives the runner with THE caller that matters most — the
# app's highest-traffic money path — lifted verbatim from the board and run
# against the runner verbatim from its partial, with walletOps stubbed at the
# seam. The board now says only WHAT it wants signed; everything else the trip
# needs has to arrive from the runner, and the only way to know it arrives is to
# watch what walletOps.run is actually handed.
#
# WHY IT IS DRIVEN RATHER THAN GREPPED. The defect this move retires is an
# absence: a hand-rolled call site that omitted redirectLink lost a real user's
# approved entry on QA. A source scan can say the board no longer spells the
# address book out. Only an execution can say the address book still REACHES
# the wallet once it does not.
class BoardEntryCallSiteJsTest < ActiveSupport::TestCase
  BOARD  = Rails.root.join("app/views/contests/_turf_totals_board.html.erb")
  RUNNER = Rails.root.join("app/views/shared/_wallet_op_runner.html.erb")

  # Bounded by the method that follows it, so a drift in either direction fails
  # here by name rather than lifting half a method into the sandbox.
  def confirm_entry_source
    src = File.read(BOARD)
    start = src.index("    async confirmEntry() {")
    assert start, "could not find confirmEntry in the board"
    finish = src.index("\n    },\n\n    showError(message) {", start)
    assert finish, "could not bound confirmEntry — the method after it moved"
    src[start...(finish + "\n    }".length)]
  end

  def runner_source
    src = File.read(RUNNER)
    src[(src.index("<script>") + "<script>".length)...src.rindex("</script>")]
  end

  # `transport:` 'inline' | 'redirect'. `left:` whether the app switch took —
  # pagehide fires INSIDE run(), the only moment it can. `run_result:` the JS
  # expression the stubbed walletOps.run answers with.
  # `returns:` the user comes back to this page (a bfcache restore) after the
  # grace window has run.
  def run_board(transport:, left: false, run_result: nil, fire_timers: true, returns: false)
    run_result ||=
      if transport == "redirect"
        # What runRedirect really resolves with once it has navigated.
        "Promise.resolve({ suspended: true, url: 'https://phantom.app/ul/v1/connect' })"
      else
        # What the intent's complete() returns: the confirm payload.
        "Promise.resolve({ success: true, tx_signature: 'SIG_INLINE', redirect: '/contests/c1' })"
      end

    script = <<~JS
      global.window = global;
      global.console = { log: function () {}, warn: function () {}, error: function () {} };
      window.location = { origin: 'https://turf.test' };
      global.document = { body: { dataset: { solanaCluster: 'devnet' } }, hidden: false,
                          addEventListener: function () {}, removeEventListener: function () {} };

      var pageHideHandlers = [];
      var pageShowHandlers = [];
      var unlistened = [];
      global.addEventListener = function (name, cb) {
        if (name === 'pagehide') pageHideHandlers.push(cb);
        if (name === 'pageshow') pageShowHandlers.push(cb);
      };
      global.removeEventListener = function (name) { unlistened.push(name); };

      // The grace window is a real setTimeout in the runner. Captured, so the test
      // decides when it fires.
      var timers = [];
      global.setTimeout = function (fn, ms) { timers.push({ fn: fn, ms: ms }); return timers.length; };

      var calls = [];
      var ran = [];
      window.SolanaStudio = { walletOps: { run: function (name, ctx, opts) {
        ran.push({ name: name, ctx: ctx,
                   opts: { expectedAccount: opts.expectedAccount, appUrl: opts.appUrl,
                           redirectLink: opts.redirectLink, cluster: opts.cluster,
                           providerTransport: opts.provider && opts.provider.transport } });
        if (#{left}) pageHideHandlers.forEach(function (cb) { cb(); });
        return (#{run_result});
      } } };

      var modal = { cards: [], visible: true };
      modal.show = function (t, b) { modal.cards.push(['show', t, b]); modal.state = 'processing'; };
      modal.error = function (b, t) { modal.cards.push(['error', t, b]); modal.state = 'error'; };
      modal.success = function (sig, t) { modal.cards.push(['success', t, sig]); modal.state = 'success'; };
      modal.setRecovery = function (label) { modal.cards.push(['recovery', label]); };
      modal.close = function () { modal.cards.push(['close']); };

      var session = { isGuest: false, isWeb3: true, address: 'LINKED_WALLET' };
      global.Alpine = { store: function (n) { return n === 'solanaModal' ? modal : (n === 'session' ? session : null); } };

      window.walletProvider = { requireProvider: function () {
        calls.push('requireProvider');
        return { transport: #{transport.to_json} };
      } };
      window.eligibilityBlocker = function () { return null; };
      window.StateFanout = { apply: function () { calls.push('fanout'); } };
      window.onchainSettled = function () { calls.push('settled'); };
      window.parseSolanaError = function (m) { return m; };
      window.reportWalletFailure = function (flow, wallet, raw, msg) { calls.push(['reportWalletFailure', flow, msg]); };
      window.tmOutstandingEntryPrepare = null;
      var cfg = { seedsPerLevel: 100 };

      #{runner_source}

      var board = {
        #{confirm_entry_source},
        submitting: false,
        contestId: 'c1',
        csrfToken: 'CSRF',
        entryFeeCents: 0,
        acceptsUsdt: false,
        contestOnchain: true,
        _fundingCheck: null,
        entryCurrency: function () { return 'usdc'; },
        setHoldLoading: function () { calls.push('setHoldLoading'); },
        setHoldSuccess: function () { calls.push('setHoldSuccess'); },
        resetHoldButtons: function () { calls.push('resetHoldButtons'); },
        mirrorTokenSpend: function () { calls.push('mirrorTokenSpend'); },
        showLoginModal: function () { calls.push('showLoginModal'); },
        showEligibilityBlockerModal: function () { calls.push('showEligibilityBlockerModal'); },
        showFundsNeeded: function () { calls.push('showFundsNeeded'); },
        showError: function (m) { calls.push(['showError', m]); },
        _handleBlockerResponse: function (d) { calls.push(['blocker', d.code]); return !!d.handled; },
        _authProps: function () { return null; }
      };

      (async function () {
        var out = {};
        try { await board.confirmEntry(); } catch (e) { out.threw = e.message; }
        out.afterRun = { submitting: board.submitting, timers: timers.length };
        if (#{fire_timers}) timers.forEach(function (t) { t.fn(); });
        if (#{returns}) pageShowHandlers.slice().forEach(function (cb) { cb({ persisted: true }); });
        out.submitting = board.submitting;
        out.delays = timers.map(function (t) { return t.ms; });
        out.ran = ran;
        out.cards = modal.cards;
        out.calls = calls;
        out.unlistened = unlistened;
        out.title = modal.title || null;
        out.lobbyUrl = modal.lobbyUrl || null;
        process.stdout.write(JSON.stringify(out));
      })();
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, "node failed: #{stderr}"
    result = JSON.parse(stdout)
    assert_nil result["threw"], "confirmEntry threw out of its own catch: #{result['threw']}"
    result
  end

  # --- the address book arrives, though the board no longer writes it -------

  test "the board says what to sign and the runner supplies the whole address book" do
    result = run_board(transport: "redirect", left: true)

    assert_equal 1, result["ran"].length, "one entry, one trip to the wallet"
    run = result["ran"].first
    assert_equal "contest_entry", run["name"], "the name the callback document looks the intent up by"
    assert_equal({ "contestId" => "c1", "csrfToken" => "CSRF", "currency" => "usdc" }, run["ctx"],
                 "the board's own arguments, journalled verbatim on the redirect transport")

    # THE REGRESSION THIS TASK EXISTS FOR. The board types none of these four now;
    # a runner that dropped one would hand the wallet a trip with no way home.
    assert_equal({ "expectedAccount" => "LINKED_WALLET",
                   "appUrl" => "https://turf.test",
                   "redirectLink" => "https://turf.test/auth/phantom/callback",
                   "cluster" => "devnet",
                   "providerTransport" => "redirect" },
                 run["opts"],
                 "every trip the board starts must carry the runner's return address, " \
                 "app identity and cluster, and the board's declared account")
    assert_equal 1, result["calls"].count("requireProvider"),
                 "the provider is acquired ONCE, by the runner, on the board's behalf"
  end

  # --- the redirect transport ----------------------------------------------

  test "a redirect trip that left paints the handoff card and never a success" do
    result = run_board(transport: "redirect", left: true)

    assert_equal [["show", "Opening Your Wallet", "Handing this entry to your wallet app…"]],
                 result["cards"],
                 "the board's own handoff copy, and nothing after it — the page is leaving"
    %w[setHoldSuccess mirrorTokenSpend settled fanout].each do |call|
      assert_not_includes result["calls"], call,
                          "the inline return leg ran on the redirect transport (#{call}) — " \
                          "an Entry Confirmed card for an entry no server has confirmed"
    end
    assert result["submitting"], "a trip that left keeps the board busy; nothing may re-enter it"
    assert_not_includes result["calls"], "resetHoldButtons"
  end

  test "a hop that never happens hands the hold buttons back and names the failure" do
    result = run_board(transport: "redirect", left: false)

    # The runner starts the grace window only once run() resolved — so it is
    # already armed when confirmEntry returns, and nothing has been released yet.
    assert_equal({ "submitting" => true, "timers" => 1 }, result["afterRun"])
    assert_equal [2500], result["delays"]

    assert_equal false, result["submitting"],
                 "submitting stayed true, so the user's retry would be refused without a reload"
    assert_includes result["calls"], "resetHoldButtons", "the hold buttons stayed dead"
    assert_equal ["error", "Wallet Did Not Open"], result["cards"].last.first(2),
                 "the card must resolve to something the user can act on, not spin forever"
  end

  test "a user who came back from the wallet without an answer gets a live board back" do
    # /tasks/frozen-wallet-overlay-traps-user, through THE caller it was found on.
    # The hop took (pagehide), so nothing was stranded — then the user swiped
    # back. The runner retires its card; what only this board can do is hand
    # back the hold buttons and clear submitting, or the retry the user came
    # back for is refused without a reload. That is the board's onStranded.
    result = run_board(transport: "redirect", left: true, returns: true)

    assert_equal %w[show close], result["cards"].map(&:first),
                 "the non-dismissible handoff card must not come back with the page"
    assert_equal false, result["submitting"], "submitting stayed true, so a retry would be refused"
    assert_includes result["calls"], "resetHoldButtons", "the hold buttons stayed dead"
  end

  # --- the inline transport ------------------------------------------------

  test "an inline entry paints the board's preparing copy and its confirmed card" do
    result = run_board(transport: "inline")

    assert_equal ["show", "Preparing Transaction", "Building onchain transaction..."], result["cards"].first,
                 "the board's progress label, carried through the runner unchanged"
    assert_includes result["cards"], ["success", "Entry Confirmed", "SIG_INLINE"]
    assert_equal "Good Luck", result["title"]
    assert_equal "/contests/c1", result["lobbyUrl"]
    %w[setHoldLoading setHoldSuccess mirrorTokenSpend fanout settled].each do |call|
      assert_includes result["calls"], call, "the inline return leg lost #{call}"
    end
    assert_equal 0, result["afterRun"]["timers"],
                 "an inline transport never navigates — a handoff watch here would tell a user " \
                 "staring at their extension that their wallet did not open"
  end

  # --- the error paths the inline copy had ---------------------------------

  test "a wrong wallet keeps the board's remedy, its report and a retryable hold" do
    err = "Object.assign(new Error('Connected wallet is not the linked one.'), { wrongAccount: true })"
    result = run_board(transport: "inline", run_result: "Promise.reject(#{err})")

    assert_equal ["error", nil, "Connected wallet is not the linked one. Or reconnect your wallet on the Account page."],
                 result["cards"].last,
                 "the runner rethrows untouched, so the board's own second remedy must still land"
    assert_includes result["calls"],
                    ["reportWalletFailure", "contest_entry",
                     "Connected wallet is not the linked one. Or reconnect your wallet on the Account page."]
    assert_includes result["calls"], "resetHoldButtons"
    assert_equal false, result["submitting"]
  end

  test "a redirect prepare refused with a blocker opens its panel and arms nothing" do
    err = "Object.assign(new Error('Add funds to enter.'), { blockerData: { code: 'no_funding', handled: true } })"
    result = run_board(transport: "redirect", run_result: "Promise.reject(#{err})")

    assert_includes result["calls"], ["blocker", "no_funding"],
                    "a blocker from the redirect prepare must reach _handleBlockerResponse"
    assert_equal false, result["submitting"]
    assert_includes result["calls"], "resetHoldButtons"
    # NOTHING WAS HANDED OFF. A watchdog left armed would paint "Wallet Did Not
    # Open" over the blocker panel 2.5s later; the runner releases the listener.
    assert_equal 0, result["afterRun"]["timers"]
    assert_includes result["unlistened"], "pagehide"
    assert_equal [["show", "Opening Your Wallet", "Handing this entry to your wallet app…"]], result["cards"],
                 "the blocker panel is the answer; no error card belongs over it"
  end
end
