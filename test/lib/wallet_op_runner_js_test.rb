require "test_helper"
require "open3"
require "json"

# [unit] window.tmWalletOp — the four things every call site must get right
# AROUND walletOps.run, each of which has cost a real user an entry in this epic.
#
# WHAT THIS TIER OWNS. walletOps.run already collapses the two transports into
# one entry point. What it does NOT supply is the return address, the app
# identity, the cluster, or a way to notice that the handoff to the wallet app
# never happened. Those were retyped at each call site, and the epic's three
# separate defects were all of that shape — something the resume needed was not
# there. This drives the wrapper directly, with walletOps stubbed at the seam.
class WalletOpRunnerJsTest < ActiveSupport::TestCase
  RUNNER = Rails.root.join("app/views/shared/_wallet_op_runner.html.erb")

  def script_body(path)
    src = File.read(path)
    src[(src.index("<script>") + "<script>".length)...src.rindex("</script>")]
  end

  # `transport:` picks which provider tmWalletOp is handed. `body` runs with:
  # ran (every walletOps.run call), modal (every card painted), stranded.
  #
  # `run_result:` is the EXPRESSION the stubbed walletOps.run answers with, and
  # it is what makes the arming ORDER observable. The default resolves
  # immediately, which is precisely the world in which the defect is invisible:
  # prepare appears to take no time, so a watchdog armed before the call and one
  # armed after it look identical. A test that never holds run open cannot see
  # which side of the handoff the timer is on.
  def run_js(body, transport: "inline", hidden: false,
             run_result: "Promise.resolve({ suspended: true })")
    script = <<~JS
      global.window = global;
      global.console = { log: function () {}, warn: function () {}, error: function () {} };
      global.location = { origin: 'https://turf.test' };
      global.document = { body: { dataset: { solanaCluster: 'devnet' } }, hidden: #{hidden} };

      // Every listener, keyed 'target:event'. removeEventListener REALLY removes,
      // so a test can see whether a watch let go of the page once it answered.
      var handlers = {};
      var pageHideHandlers = handlers['window:pagehide'] = [];
      function listen(target) {
        return function (name, cb) { (handlers[target + ':' + name] = handlers[target + ':' + name] || []).push(cb); };
      }
      function unlisten(target) {
        return function (name, cb) {
          var list = handlers[target + ':' + name] || [];
          var i = list.indexOf(cb);
          if (i >= 0) list.splice(i, 1);
        };
      }
      global.addEventListener = listen('window');
      global.removeEventListener = unlisten('window');
      document.addEventListener = listen('document');
      document.removeEventListener = unlisten('document');
      global.listening = function (key) { return (handlers[key] || []).length; };

      // The grace window is a real setTimeout in the source. Captured rather than
      // waited on, so the test decides when it fires.
      var timers = [];
      global.setTimeout = function (fn, ms) { timers.push({ fn: fn, ms: ms }); return timers.length; };

      var ran = [];
      window.SolanaStudio = { walletOps: { run: function (name, ctx, opts) { ran.push({ name: name, ctx: ctx, opts: opts }); return (#{run_result}); } } };

      var modal = { cards: [], visible: true, state: null };
      modal.show = function (t, b) { modal.cards.push(['show', t, b]); modal.visible = true; modal.state = 'processing'; };
      modal.error = function (b, t) { modal.cards.push(['error', t, b]); modal.state = 'error'; };
      modal.close = function () { modal.cards.push(['close']); modal.visible = false; modal.state = null; };
      global.Alpine = { store: function (n) { return n === 'solanaModal' ? modal : null; } };

      var provider = { transport: #{transport.to_json}, name: 'stub' };
      window.walletProvider = { requireProvider: function () { return provider; } };

      #{script_body(RUNNER)}

      // The body fires this AFTER the run has armed the watch — arming happens
      // inside tmWalletOp, so a pagehide fired earlier would land on nothing and
      // the test would pass for the wrong reason.
      global.firePageHide = function () { pageHideHandlers.slice().forEach(function (cb) { cb(); }); };

      // THE WAY BACK. A bfcache restore is a pageshow with persisted true; an app
      // switch that never unloaded the page is a visibilitychange. Copied before
      // iterating, because a handler that answers removes itself.
      global.firePageShow = function (persisted) {
        (handlers['window:pageshow'] || []).slice().forEach(function (cb) { cb({ persisted: persisted }); });
      };
      global.fireVisibility = function (hiddenNow) {
        document.hidden = hiddenNow;
        (handlers['document:visibilitychange'] || []).slice().forEach(function (cb) { cb({}); });
      };

      (async function () {
        var out;
        try {
          out = await (async function () { #{body} })();
        } catch (e) {
          out = { error: e.message };
        }
        process.stdout.write(JSON.stringify(out));
      })();
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, "node failed: #{stderr}"
    JSON.parse(stdout)
  end

  # A world with NO Alpine, NO provider and NO walletOps — just the fetch helper
  # and whatever fetch shape the caller asks for. `authed:` supplies
  # window.authedFetch; `status:` is what a plain window.fetch answers with.
  def run_fetch_js(body, authed: false, status: 200)
    script = <<~JS
      global.window = global;
      var calls = [];
      #{authed ? "window.authedFetch = function (u, o) { calls.push(['authed', u]); return Promise.resolve('AUTHED-RESPONSE'); };" : ''}
      global.fetch = function (u, o) { calls.push(['plain', u]); return Promise.resolve({ status: #{status}, body: 'PLAIN-RESPONSE' }); };
      window.fetch = global.fetch;

      #{script_body(RUNNER)}

      (async function () {
        var out;
        try {
          out = await (async function () { #{body} })();
        } catch (e) {
          out = { error: e.message };
        }
        out.calls = calls;
        process.stdout.write(JSON.stringify(out));
      })();
    JS

    stdout, stderr, status_out = Open3.capture3("node", "--eval", script)
    assert status_out.success?, "node failed: #{stderr}"
    JSON.parse(stdout)
  end

  # --- the fetch the callback document actually has ------------------------
  #
  # THE DEFECT THESE EXIST FOR. window.authedFetch ships only in the DEFERRED
  # importmap module solana_utils.js, while studio-engine's phantom_callback
  # dispatches from a bare inline script during body parse and wallet_ops calls
  # complete() SYNCHRONOUSLY. So on the ONE document that matters it is not there
  # yet, and a handler calling it directly throws a TypeError AFTER the user has
  # approved in their wallet, with the journal already consumed by take().
  #
  # AND THE 401 NORMALISATION IS THE HALF THAT FAILS SILENTLY. authedFetch
  # answers FALSY on a 401 (having surfaced the login modal); plain fetch answers
  # a 401 Response, which is TRUTHY. Every handler branches on `if (!resp)`, so a
  # fallback that returned the Response unchanged reads an expired session as a
  # successful prepare — and carries an empty transaction to the wallet.

  test "with no authedFetch, a 401 is normalised to the falsy shape handlers branch on" do
    result = run_fetch_js("return { resp: await window.tmWalletFetch('/prepare', {}) };", status: 401)

    assert_nil result["resp"],
               "a 401 Response is TRUTHY — returned unchanged it reads as a prepared transaction"
    assert_equal [["plain", "/prepare"]], result["calls"]
  end

  test "with no authedFetch, a 200 comes back untouched" do
    # THE CONTROL. A helper that answered falsy for everything would pass the
    # test above and break every successful request.
    result = run_fetch_js("var r = await window.tmWalletFetch('/prepare', {}); return { body: r && r.body };")

    assert_equal "PLAIN-RESPONSE", result["body"]
  end

  test "authedFetch is preferred whenever the document has it" do
    # It is the one that surfaces the login modal and the rate-limit card. The
    # fallback exists for the callback page, not as a replacement.
    result = run_fetch_js("return { resp: await window.tmWalletFetch('/prepare', {}) };", authed: true)

    assert_equal "AUTHED-RESPONSE", result["resp"]
    assert_equal [["authed", "/prepare"]], result["calls"],
                 "the plain fetch must not be reached when authedFetch is present"
  end

  CALL = "await window.tmWalletOp('contest_create', { contestId: 9 }, { expectedAccount: 'WALLET1' });".freeze

  # --- the return address, and everything else the trip needs --------------

  test "every run carries the callback return address, app identity and cluster" do
    result = run_js(<<~JS, transport: "redirect")
      #{CALL}
      return { opts: ran[0].opts, ctx: ran[0].ctx, name: ran[0].name };
    JS

    # THE RETURN ADDRESS IS THE ONE THAT COST A REAL ENTRY. redirectLink is where
    # the wallet comes back to; a run without it hands the wallet a trip with no
    # way home, and the loss lands AFTER the user has approved.
    assert_equal({ "expectedAccount" => "WALLET1",
                   "appUrl" => "https://turf.test",
                   "redirectLink" => "https://turf.test/auth/phantom/callback",
                   "cluster" => "devnet" },
                 result["opts"].except("provider"),
                 "these four are the trip's whole address book; each was retyped per call site before")
    assert_equal "contest_create", result["name"]
    assert_equal({ "contestId" => 9 }, result["ctx"], "the caller's ctx is passed through untouched")
  end

  test "an undeclared expected account is passed as null, not as a string" do
    result = run_js(<<~JS)
      await window.tmWalletOp('contest_bundle', {}, {});
      return { expected: ran[0].opts.expectedAccount };
    JS

    # walletOps REFUSES a non-string expectedAccount rather than stringifying it,
    # because a PublicKey String()s correctly inline and journals as {} on the
    # redirect path — matching on a desktop and refusing every phone with a
    # wrong-wallet sentence naming an account nobody has.
    assert_nil result["expected"]
  end

  # --- the handoff that never happens --------------------------------------

  test "a redirect that never leaves the page surfaces an error and releases the caller" do
    result = run_js(<<~JS, transport: "redirect")
      var stranded = 0;
      await window.tmWalletOp('contest_create', {}, { onStranded: function () { stranded += 1; } });
      timers.forEach(function (t) { t.fn(); });
      return { stranded: stranded, cards: modal.cards, delay: timers[0] && timers[0].ms };
    JS

    # run() ends by handing the OS a universal link, and "nothing after this
    # executes" is only true when the OS honours it. If the wallet is not
    # installed, or the user dismisses the app switch, this document stays alive
    # holding a modal that never resolves and buttons that never come back.
    assert_equal 1, result["stranded"], "the caller must be told, so it can re-enable its own controls"
    assert_equal ["error", "Wallet Did Not Open"], result["cards"].last.first(2),
                 "and the user must be told, in the card they are already looking at"
    assert_equal 2500, result["delay"], "the window only has to outlast the OS app-switch prompt"
  end

  test "a redirect that DID leave the page strands nothing" do
    # pagehide is the SIGNAL, not the timer. It fires when the app switch takes,
    # so a run that fired it must never be reported as stranded — that would put
    # "your wallet did not open" in front of a user whose wallet did open, on the
    # page they return to.
    result = run_js(<<~JS, transport: "redirect")
      var stranded = 0;
      await window.tmWalletOp('contest_create', {}, { onStranded: function () { stranded += 1; } });
      firePageHide();
      timers.forEach(function (t) { t.fn(); });
      return { stranded: stranded, cards: modal.cards.map(function (c) { return c[0]; }) };
    JS

    assert_equal 0, result["stranded"]
    assert_equal ["show"], result["cards"], "no error card belongs on a trip that left"
  end

  test "a redirect hidden mid-app-switch strands nothing even before pagehide" do
    # THE iOS CASE, AND THE ONLY TEST THAT REACHES THE `|| document.hidden` HALF
    # OF THE GUARD. On iOS the app switch can be in flight — the document already
    # hidden — while pagehide has NOT fired yet. Judging that trip on pagehide
    # alone reports it stranded, so the user watches Phantom open and reads
    # "Wallet Did Not Open" behind it, then returns to a page that has already
    # released its own controls.
    #
    # Without this, deleting `|| document.hidden` from watchHandoff leaves the
    # whole suite green: every other stranded test runs with hidden false, so the
    # one line in this file written specifically for iOS was unguarded.
    result = run_js(<<~JS, transport: "redirect", hidden: true)
      var stranded = 0;
      await window.tmWalletOp('contest_create', {}, { onStranded: function () { stranded += 1; } });
      // NO firePageHide() — that is the whole point: the switch took, but the
      // event this document would learn it from has not arrived.
      timers.forEach(function (t) { t.fn(); });
      return { stranded: stranded, cards: modal.cards.map(function (c) { return c[0]; }) };
    JS

    assert_equal 0, result["stranded"],
                 "the document is hidden, so the OS did switch apps — releasing the caller " \
                 "here re-enables buttons behind a wallet that is actively signing"
    assert_equal ["show"], result["cards"],
                 "and no error card belongs in front of a user whose wallet did open"
  end

  # --- WHICH SIDE OF THE HANDOFF THE WATCHDOG STARTS ON --------------------
  #
  # THE VALUE WAS PORTED FROM THE BOARD; THE STARTING GUN WAS NOT.
  # contests/_turf_totals_board armed this same 2500ms timer AFTER awaiting run,
  # back when it carried its own inline copy (it calls this wrapper now).
  # This wrapper armed it BEFORE the call — and runRedirect AWAITS prepare()
  # and navigates second, so the window meant to outlast an OS app-switch prompt
  # was being asked to cover prepare's network round trips as well. Contest
  # creation is the worst case: a multipart banner upload plus a rebuild POST.

  test "the grace window starts when the wallet was handed the link, not when prepare began" do
    # run() is HELD OPEN here, which is the only way the order is observable: an
    # immediately-resolved run makes "armed before" and "armed after" identical.
    result = run_js(<<~JS, transport: "redirect",
      var stranded = 0;
      var trip = window.tmWalletOp('contest_create', {}, { onStranded: function () { stranded += 1; } });

      // Still inside prepare — on a real create, mid banner upload.
      var duringPrepare = { timers: timers.length, listeners: pageHideHandlers.length };

      releaseRun();
      await trip;
      var afterHandoff = { timers: timers.length, listeners: pageHideHandlers.length };

      timers.forEach(function (t) { t.fn(); });
      return { duringPrepare: duringPrepare, afterHandoff: afterHandoff, stranded: stranded,
               delay: timers[0] && timers[0].ms, cards: modal.cards };
    JS
                    run_result: "new Promise(function (res) { global.releaseRun = function () { res({ suspended: true }); }; })")

    # THE LISTENER IS THE HALF THAT MUST BE EARLY. The navigation it watches for
    # happens INSIDE run(), so attaching it afterwards registers a handler for an
    # event that has already gone by.
    assert_equal({ "timers" => 0, "listeners" => 1 }, result["duringPrepare"],
                 "a slow create paints \"your wallet app did not open\" moments before Phantom " \
                 "opens when this counts down through prepare")

    assert_equal({ "timers" => 1, "listeners" => 1 }, result["afterHandoff"],
                 "the link is with the OS now — this is the first moment there is an app switch to wait on")
    assert_equal 2500, result["delay"], "the window only has to outlast the OS app-switch prompt"

    # AND IT STILL FIRES. Moving the start must not disarm the guard: a trip that
    # was handed off and never left is still stranded, and still says so.
    assert_equal 1, result["stranded"]
    assert_equal ["error", "Wallet Did Not Open"], result["cards"].last.first(2)
  end

  test "a prepare that failed leaves ITS OWN message on the card" do
    # NOT A RACE — DETERMINISTIC. On a create that genuinely fails, the caller's
    # catch paints the real cause immediately and the watchdog overwrote it 2.5s
    # later, EVERY time, so the operator never saw why. The trip never reached
    # the wallet, so there is no handoff to wait on and nothing to arm.
    result = run_js(<<~JS, transport: "redirect",
      var stranded = 0;
      var message = null;
      try {
        await window.tmWalletOp('contest_create', {}, { onStranded: function () { stranded += 1; } });
      } catch (e) {
        message = e.message;
        // Exactly what contests/new does with it.
        modal.error(e.message, 'Contest Creation Failed');
      }
      timers.forEach(function (t) { t.fn(); });
      return { message: message, timers: timers.length, stranded: stranded, cards: modal.cards };
    JS
                    run_result: "Promise.reject(new Error('Your session expired — sign in and try again.'))")

    # Asserted as the ONE right card, not as "no wallet error was shown" — that
    # weaker claim passes when the wrong error is shown too.
    assert_equal ["error", "Contest Creation Failed", "Your session expired — sign in and try again."],
                 result["cards"].last,
                 "the cause the user can act on has to be the card still standing"
    assert_equal 0, result["timers"], "there was no handoff, so there is no grace window to run"
    assert_equal 0, result["stranded"], "the caller already released its own controls in its catch"
    assert_equal "Your session expired — sign in and try again.", result["message"],
                 "the rejection reaches the caller untouched — this wrapper diagnoses nothing"
  end

  # --- the way back: the user returns and the wallet never answered ----------
  #
  # /tasks/frozen-wallet-overlay-traps-user. The trap, in order: the user taps
  # to enter, the NON-DISMISSIBLE processing card paints "Opening Your Wallet",
  # the phone switches to the wallet app, and the user comes back without acting.
  # pagehide had already told the watch the hop took, so nothing was left
  # watching — and the card came back with the page, with no Close button and
  # the body's scroll lock still on, which also kills pull-to-refresh. The user
  # was stuck until they closed the tab.
  #
  # WHY RETIRING IS SAFE HERE AND NOWHERE ELSE. On the redirect transport the
  # wallet's answer NEVER lands on this document: it lands on the callback page,
  # which finishes the intent by name. So once the link was handed off, a user
  # looking at this page again is, by construction, a user this page will hear
  # nothing more for. Before the handoff that is not true — prepare is still
  # running and will navigate — and on the inline transport it is never true.

  test "a trip that came back from the bfcache retires the card and releases the caller" do
    result = run_js(<<~JS, transport: "redirect")
      var released = 0;
      await window.tmWalletOp('contest_entry', {}, { onStranded: function () { released += 1; } });
      firePageHide();                                  // the hop took
      timers.forEach(function (t) { t.fn(); });        // so nothing is stranded
      var beforeReturn = modal.cards.map(function (c) { return c[0]; });
      firePageShow(true);                              // ...and the user swiped back
      return { released: released, beforeReturn: beforeReturn,
               cards: modal.cards.map(function (c) { return c[0]; }),
               watching: listening('window:pageshow') + listening('document:visibilitychange') };
    JS

    assert_equal ["show"], result["beforeReturn"], "sanity: the hop took, so no error card went up"
    assert_equal %w[show close], result["cards"],
                 "the non-dismissible card must not survive the way back — it is the whole trap"
    assert_equal 1, result["released"],
                 "the caller's hold buttons and submitting flag must come back with the page, " \
                 "or the retry the user came back for is refused"
    assert_equal 0, result["watching"], "a watch that has answered lets go of the page"
  end

  test "an app switch that never unloaded the page is a way back too" do
    # THE iOS SHAPE THE BFCACHE SIGNAL CANNOT SEE. Opening a wallet app from a
    # universal link need not unload this document at all: it goes hidden, the
    # wallet takes the screen, and coming back makes it visible again. No
    # pageshow fires, because nothing was restored.
    result = run_js(<<~JS, transport: "redirect", hidden: true)
      var released = 0;
      await window.tmWalletOp('contest_entry', {}, { onStranded: function () { released += 1; } });
      timers.forEach(function (t) { t.fn(); });        // hidden, so the hop took
      var beforeReturn = modal.cards.map(function (c) { return c[0]; });
      fireVisibility(false);                           // back from the wallet app
      return { released: released, beforeReturn: beforeReturn,
               cards: modal.cards.map(function (c) { return c[0]; }) };
    JS

    assert_equal ["show"], result["beforeReturn"]
    assert_equal %w[show close], result["cards"]
    assert_equal 1, result["released"]
  end

  test "coming back inside the grace window retires once and strands nothing" do
    # The quickest abandon there is: the app switch took and the user was back
    # before the 2.5s window ran out. The window must not then report "your
    # wallet did not open" on a card the way back has already retired.
    result = run_js(<<~JS, transport: "redirect")
      var released = 0;
      await window.tmWalletOp('contest_entry', {}, { onStranded: function () { released += 1; } });
      fireVisibility(true);
      fireVisibility(false);
      firePageShow(true);                              // a second signal for the same return
      timers.forEach(function (t) { t.fn(); });
      return { released: released, cards: modal.cards.map(function (c) { return c[0]; }) };
    JS

    assert_equal %w[show close], result["cards"], "one return, one retirement, no error card after it"
    assert_equal 1, result["released"]
  end

  test "a return before the handoff is not a return: prepare is still running" do
    # "STILL WAITING FOR ONE", the half of the distinction that keeps the card.
    # Until run() resolves, the link has not reached the OS and prepare will
    # still navigate to the wallet. Retiring the card here would unlock the
    # board under a trip that is about to leave.
    result = run_js(<<~JS, transport: "redirect",
      var released = 0;
      var trip = window.tmWalletOp('contest_entry', {}, { onStranded: function () { released += 1; } });
      fireVisibility(true);
      fireVisibility(false);
      firePageShow(true);
      var duringPrepare = modal.cards.map(function (c) { return c[0]; });
      releaseRun();
      await trip;
      return { released: released, duringPrepare: duringPrepare,
               cards: modal.cards.map(function (c) { return c[0]; }) };
    JS
                    run_result: "new Promise(function (res) { global.releaseRun = function () { res({ suspended: true }); }; })")

    assert_equal ["show"], result["duringPrepare"]
    assert_equal ["show"], result["cards"], "the handoff happened after these events, so none was a return"
    assert_equal 0, result["released"]
  end

  test "a pageshow that is not a bfcache restore retires nothing" do
    # persisted false is an ordinary load of a NEW document — this one never
    # left, so there is nothing to come back from.
    result = run_js(<<~JS, transport: "redirect")
      var released = 0;
      await window.tmWalletOp('contest_entry', {}, { onStranded: function () { released += 1; } });
      firePageHide();
      timers.forEach(function (t) { t.fn(); });
      firePageShow(false);
      return { released: released, cards: modal.cards.map(function (c) { return c[0]; }) };
    JS

    assert_equal ["show"], result["cards"]
    assert_equal 0, result["released"]
  end

  test "a stranded trip keeps its error card through a later return" do
    # The hop never happened, so the user is already reading "Wallet Did Not
    # Open" on a card they can close. A tab switch afterwards is not a return
    # from a wallet, and must not pull that explanation out from under them or
    # release the caller a second time.
    result = run_js(<<~JS, transport: "redirect")
      var released = 0;
      await window.tmWalletOp('contest_entry', {}, { onStranded: function () { released += 1; } });
      timers.forEach(function (t) { t.fn(); });        // never left: stranded
      fireVisibility(true);
      fireVisibility(false);
      firePageShow(true);
      return { released: released, cards: modal.cards.map(function (c) { return c[0]; }),
               watching: listening('window:pageshow') + listening('document:visibilitychange') };
    JS

    assert_equal %w[show error], result["cards"]
    assert_equal 1, result["released"], "released once, by the stranded path"
    assert_equal 0, result["watching"]
  end

  test "a return retires only a card that is still waiting" do
    # The runner owns the processing card it painted, not whatever the store
    # shows by the time the user is back. A card another step has already
    # resolved is left for its own buttons.
    result = run_js(<<~JS, transport: "redirect")
      var released = 0;
      await window.tmWalletOp('contest_entry', {}, { onStranded: function () { released += 1; } });
      firePageHide();
      timers.forEach(function (t) { t.fn(); });
      modal.state = 'success';
      firePageShow(true);
      return { released: released, cards: modal.cards.map(function (c) { return c[0]; }) };
    JS

    assert_equal ["show"], result["cards"], "a resolved card is not the runner's to close"
    assert_equal 1, result["released"], "the caller's own flow on this page is still over"
  end

  test "an inline run arms no handoff watch at all" do
    # THE CONTROL, and it is load-bearing. An inline transport NEVER navigates —
    # so a watch armed here would fire on every desktop signature and tell a user
    # staring at their extension that their wallet did not open. And the inline
    # promise is still live across a tab switch, so a return watch here would
    # retire the card in front of a transaction that is still confirming.
    result = run_js(<<~JS, transport: "inline")
      var stranded = 0;
      await window.tmWalletOp('contest_create', {}, { onStranded: function () { stranded += 1; } });
      timers.forEach(function (t) { t.fn(); });
      fireVisibility(true);
      fireVisibility(false);
      firePageShow(true);
      return { stranded: stranded, timers: timers.length, cards: modal.cards,
               watching: listening('window:pageshow') + listening('document:visibilitychange') };
    JS

    assert_equal 0, result["timers"], "no grace window belongs on a transport that cannot navigate"
    assert_equal 0, result["watching"], "no return watch either — this page is still the one waiting"
    assert_equal 0, result["stranded"]
    assert_equal 1, result["cards"].length, "the processing card stays up for the inline answer"
    assert_equal "Preparing Transaction", result["cards"].first[1],
                 "an inline run paints the preparing card, not the handoff card"
  end

  test "the card copy tracks the transport rather than the device" do
    redirect = run_js("await window.tmWalletOp('contest_create', {}, {}); return { card: modal.cards[0] };",
                      transport: "redirect")
    inline = run_js("await window.tmWalletOp('contest_create', {}, {}); return { card: modal.cards[0] };")

    assert_equal "Opening Your Wallet", redirect["card"][1]
    assert_equal "Preparing Transaction", inline["card"][1]
  end

  # --- what a caller may still say, and what it gets back ------------------
  #
  # THE TURF-TOTALS BOARD IS WHY THESE EXIST (/tasks/route-board-through-runner).
  # It kept its own progress labels when it moved behind this runner, and it
  # ends its redirect leg on the value this hands back — so both halves of that
  # contract are asserted here, where the runner owns them.

  test "a caller's own card body is shown on each transport, under the runner's title" do
    opts = "{ preparingBody: 'Building onchain transaction...', handoffBody: 'Handing this entry to your wallet app…' }"
    redirect = run_js("await window.tmWalletOp('contest_entry', {}, #{opts}); return { card: modal.cards[0] };",
                      transport: "redirect")
    inline = run_js("await window.tmWalletOp('contest_entry', {}, #{opts}); return { card: modal.cards[0] };")

    assert_equal ["show", "Opening Your Wallet", "Handing this entry to your wallet app…"], redirect["card"]
    assert_equal ["show", "Preparing Transaction", "Building onchain transaction..."], inline["card"],
                 "a body the caller passed must replace the default, on the transport it names only"
  end

  test "the redirect marker reaches the caller untouched" do
    # A caller ends its redirect leg on `result.suspended`. A wrapper that
    # swallowed or rebuilt the value would send that caller into its inline
    # return leg — an Entry Confirmed card on a document on its way to the wallet.
    result = run_js("return { value: await window.tmWalletOp('contest_entry', {}, {}) };", transport: "redirect",
                    run_result: "Promise.resolve({ suspended: true, url: 'https://phantom.app/ul/v1/connect' })")

    assert_equal({ "suspended" => true, "url" => "https://phantom.app/ul/v1/connect" }, result["value"])
  end
end
