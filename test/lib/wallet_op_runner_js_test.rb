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
  def run_js(body, transport: "inline", hidden: false)
    script = <<~JS
      global.window = global;
      global.console = { log: function () {}, warn: function () {}, error: function () {} };
      global.location = { origin: 'https://turf.test' };
      global.document = { body: { dataset: { solanaCluster: 'devnet' } }, hidden: #{hidden} };

      var pageHideHandlers = [];
      global.addEventListener = function (name, cb) { if (name === 'pagehide') pageHideHandlers.push(cb); };
      global.removeEventListener = function () {};

      // The grace window is a real setTimeout in the source. Captured rather than
      // waited on, so the test decides when it fires.
      var timers = [];
      global.setTimeout = function (fn, ms) { timers.push({ fn: fn, ms: ms }); return timers.length; };

      var ran = [];
      window.SolanaStudio = { walletOps: { run: function (name, ctx, opts) { ran.push({ name: name, ctx: ctx, opts: opts }); return Promise.resolve({ suspended: true }); } } };

      var modal = { cards: [], visible: true };
      modal.show = function (t, b) { modal.cards.push(['show', t, b]); };
      modal.error = function (b, t) { modal.cards.push(['error', t, b]); };
      global.Alpine = { store: function (n) { return n === 'solanaModal' ? modal : null; } };

      var provider = { transport: #{transport.to_json}, name: 'stub' };
      window.walletProvider = { requireProvider: function () { return provider; } };

      #{script_body(RUNNER)}

      // The body fires this AFTER the run has armed the watch — arming happens
      // inside tmWalletOp, so a pagehide fired earlier would land on nothing and
      // the test would pass for the wrong reason.
      global.firePageHide = function () { pageHideHandlers.forEach(function (cb) { cb(); }); };

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

  test "an inline run arms no handoff watch at all" do
    # THE CONTROL, and it is load-bearing. An inline transport NEVER navigates —
    # so a watch armed here would fire on every desktop signature and tell a user
    # staring at their extension that their wallet did not open.
    result = run_js(<<~JS, transport: "inline")
      var stranded = 0;
      await window.tmWalletOp('contest_create', {}, { onStranded: function () { stranded += 1; } });
      timers.forEach(function (t) { t.fn(); });
      return { stranded: stranded, timers: timers.length, cards: modal.cards };
    JS

    assert_equal 0, result["timers"], "no grace window belongs on a transport that cannot navigate"
    assert_equal 0, result["stranded"]
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
end
