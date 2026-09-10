require "test_helper"
require "open3"
require "json"

# The contest_entry intent's two halves, EXECUTED against the real view source.
#
# WHY THESE TWO FUNCTIONS EXIST AT ALL. On the redirect transport the page is
# DESTROYED between preparing a transaction and getting it back signed — the
# wallet app takes over and the browser may not even return to the same tab. So
# the flow is split at that seam: prepare() runs in the document that starts the
# entry, complete() runs in whatever document the wallet returns to, and they
# share NOTHING but their arguments. Anything either of them kept in a closure
# would be gone.
#
# ASSERTED BY RUNNING THE SHIPPED SOURCE, not a paraphrase of it. The functions
# are lifted out of the partial verbatim and driven in node, because the two
# properties that matter here — "everything prepare returns survives JSON" and
# "complete refuses a broadcast" — are behaviour, and a source-text assertion
# cannot see either.
class ContestEntryIntentJsTest < ActiveSupport::TestCase
  # THE HANDLERS MOVED. They began in the contest board, which is exactly
  # the placement that lost the entry: the board renders on two contest
  # pages and the wallet returns to neither. They now live in the partial
  # the LAYOUT renders, so every document carries them.
  PARTIAL = Rails.root.join("app/views/shared/_contest_entry_intent.html.erb")

  # Pull both handlers out of the view verbatim.
  def handlers_source
    src = File.read(PARTIAL)
    # THE DEFINITION, not the first mention. The intent registration above it
    # CALLS window.tmPrepareContestEntry(ctx), so a bare index() lands mid-object
    # and extracts syntactically broken JS.
    start = src.index("window.tmEntryFetch = function")
    finish = src.index("</script>")
    assert start, "could not find tmEntryFetch in the partial"
    assert finish && finish > start, "could not bound the handler block"
    src[start...finish]
  end

  # `fetch:` describes what authedFetch answers — :ok, :unauthorized (falsy, the
  # 401 shape), or a hash body with success:false.
  def run_js(script, fetch: :ok, body: nil)
    fetch_js =
      case fetch
      when :unauthorized then "window.authedFetch = function () { calls.push(['fetch', arguments[0], arguments[1]]); return Promise.resolve(null); };"
      when :no_authed_fetch
        # THE CALLBACK DOCUMENT. authedFetch ships in a DEFERRED importmap module
        # and complete() runs from a bare inline script during body parse, so on
        # the one page that matters it is simply not there yet. Every other shape
        # in this method SUPPLIES it — which is exactly why the suite could not
        # see the TypeError that lost a user's approved entry.
        "window.fetch = function (u, o) { calls.push(['fetch', u, o]); " \
          "return Promise.resolve({ status: 200, json: function () { return Promise.resolve(" +
          ({ "success" => true, "serialized_tx" => "AQID", "ptx_slug" => "ptx-1", "entry_id" => 7,
             "entry_pda" => "PDA", "token_funded" => true, "tx_signature" => "SIG" }.to_json) +
          "); } }); };"
      when :no_authed_fetch_401
        "window.fetch = function (u, o) { calls.push(['fetch', u, o]); " \
          "return Promise.resolve({ status: 401, json: function () { return Promise.resolve({}); } }); };"
      else
        payload = (body || {
          "success" => true, "serialized_tx" => "AQID", "ptx_slug" => "ptx-1",
          "entry_id" => 7, "entry_pda" => "PDA", "token_funded" => true,
          "tx_signature" => "SIG"
        }).to_json
        "window.authedFetch = function (u, o) { calls.push(['fetch', u, o]); " \
          "return Promise.resolve({ json: function () { return Promise.resolve(#{payload}); } }); };"
      end

    full = <<~JS
      global.window = global;
      var calls = [];
      #{fetch_js}
      // The gem's codec, stubbed at its PUBLIC surface only. base58 itself is
      // driven by its own suite in solana-studio; what is under test here is
      // whether these handlers convert in the right DIRECTION at each end.
      window.SolanaStudio = { walletTransport: { base58: {
        encode: function (bytes) { return 'B58<' + Array.from(bytes).join(',') + '>'; },
        decode: function (s) { return new Uint8Array(String(s).replace(/^B58</, '').replace(/>$/, '').split(',').map(Number)); }
      } } };
      console.log = function () {};
      #{handlers_source}
      var RESULT;
      (async function () {
        try { RESULT = { ok: true, value: await (#{script}) }; }
        // blockerData rides the Error so the board's catch can route a failed
        // prepare to the right panel — carry it out of node too, or the test
        // below can only see the flattened string this change exists to avoid.
        // `code` rides beside blockerData and for the same reason: the survivor
        // board routes a 'tx_rejected' refusal to its own reassuring modal
        // WITHOUT reading the rest of the payload, and on the redirect transport
        // its catch runs on a document that never saw the response. Carry it out
        // of node too, or the test below can only see the flattened string.
        catch (e) { RESULT = { ok: false, message: e.message, blockerData: e.blockerData || null, code: e.code || null }; }
        RESULT.calls = calls;
        process.stdout.write(JSON.stringify(RESULT));
      })();
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", full)
    assert status.success?, "node failed: #{stderr}"
    JSON.parse(stdout)
  end

  # --- prepare -------------------------------------------------------------

  test "prepare returns only values that survive being written to storage" do
    # THE CONTRACT THE REDIRECT TRANSPORT IMPOSES: this return value is
    # serialised to localStorage verbatim. A Transaction object, a function or a
    # DOM node here would arrive on the other side as {} and the entry would fail
    # after the user had already approved it in their wallet.
    result = run_js("window.tmPrepareContestEntry({ contestId: 12, csrfToken: 'T', currency: 'usdc' })")

    assert result["ok"], result["message"]
    state = result["value"]
    assert_equal JSON.parse(state.to_json), state, "everything prepare returns must round-trip through JSON"
    assert_equal %w[entry_id entry_pda ptx_slug token_funded transaction].sort, state.keys.sort
    # base64 "AQID" is bytes 1,2,3 — proving the base64→base58 hop actually ran.
    assert_equal "B58<1,2,3>", state["transaction"]
    assert_equal "ptx-1", state["ptx_slug"]
  end

  test "prepare posts the currency the caller chose to the right contest" do
    result = run_js("window.tmPrepareContestEntry({ contestId: 12, csrfToken: 'T', currency: 'usdt' })")

    url, opts = result["calls"].first[1], result["calls"].first[2]
    assert_equal "/contests/12/prepare_entry", url
    assert_equal({ "currency" => "usdt" }, JSON.parse(opts["body"]))
    assert_equal "T", opts["headers"]["X-CSRF-Token"]
  end

  test "prepare THROWS on a 401 rather than returning nothing" do
    # THE BUG THIS PINS, and it is easy to write by accident: the inline flow
    # `return`s here, because authedFetch has already surfaced the login modal.
    # A handler must THROW — walletOps is awaiting a promise, and a silent
    # undefined would read as a successfully prepared entry and send the user to
    # a wallet with nothing to sign.
    result = run_js("window.tmPrepareContestEntry({ contestId: 1, csrfToken: 'T', currency: 'usdc' })",
                    fetch: :unauthorized)

    refute result["ok"], "a 401 must reject, not resolve"
    assert_match(/session expired/i, result["message"])
  end

  test "prepare surfaces the server's own refusal" do
    result = run_js("window.tmPrepareContestEntry({ contestId: 1, csrfToken: 'T', currency: 'usdc' })",
                    body: { "success" => false, "error" => "Contest is full" })

    refute result["ok"]
    assert_equal "Contest is full", result["message"]
  end

  # --- complete ------------------------------------------------------------

  test "complete refuses a wallet that broadcast instead of signing" do
    # SIGN-ONLY IS A REQUIREMENT, not a preference. prepare_entry returns a
    # transaction whose admin slot is deliberately EMPTY and the SERVER cosigns
    # and broadcasts. A wallet that broadcast it returns a signature and no
    # transaction — and there is nothing to recover, because the server never
    # received the bytes it must cosign. Refusing loudly beats POSTing an empty
    # body and reporting a failure the user cannot act on.
    result = run_js("window.tmCompleteContestEntry({ contestId: 1, csrfToken: 'T' }, " \
                    "{ signature: 'SIG', signedTransaction: null }, { ptx_slug: 'p' })")

    refute result["ok"]
    assert_match(/broadcast this entry instead of signing/i, result["message"])
    assert_empty result["calls"], "nothing may be posted when there is no signed transaction"
  end

  test "complete hands the server the signed bytes and the ids from prepare" do
    result = run_js("window.tmCompleteContestEntry(" \
                    "{ contestId: 12, csrfToken: 'T' }, " \
                    "{ signedTransaction: 'B58<1,2,3>' }, " \
                    "{ ptx_slug: 'ptx-1', entry_id: 7, entry_pda: 'PDA' })")

    assert result["ok"], result["message"]
    url, opts = result["calls"].first[1], result["calls"].first[2]
    assert_equal "/contests/12/confirm_onchain_entry", url

    body = JSON.parse(opts["body"])
    # base58 back to base64 — bytes 1,2,3 are "AQID". The round trip is the whole
    # point: the wallet speaks base58, the server speaks base64.
    assert_equal "AQID", body["signed_tx"]
    # THE IDS COME FROM `state`, which crossed the page death — not from a
    # closure, which could not have.
    assert_equal 7, body["entry_id"]
    assert_equal "PDA", body["entry_pda"]
    assert_equal "ptx-1", body["ptx_slug"]
  end

  test "complete surfaces a server refusal rather than reporting success" do
    result = run_js("window.tmCompleteContestEntry({ contestId: 1, csrfToken: 'T' }, " \
                    "{ signedTransaction: 'B58<1>' }, { ptx_slug: 'p' })",
                    body: { "success" => false, "error" => "Entry already recorded" })

    refute result["ok"]
    assert_equal "Entry already recorded", result["message"]
  end

  # A REFUSED COSIGN IS NOT A GENERIC ERROR EITHER. The server returns
  # code 'tx_rejected' (422) when the submitted transaction did not match the
  # prepared entry, and both boards answer it with a reassuring modal rather than
  # a red error card. That code exists ONLY on this response, and on the redirect
  # transport the board's catch runs on a document that never saw it — so the
  # code has to ride the Error, exactly as blockerData does on the way in.
  test "complete carries the server's refusal CODE on the error it throws" do
    result = run_js("window.tmCompleteContestEntry({ contestId: 1, csrfToken: 'T' }, " \
                    "{ signedTransaction: 'B58<1>' }, { ptx_slug: 'p' })",
                    body: { "success" => false, "error" => "We could not co-sign that entry",
                            "code" => "tx_rejected" })

    refute result["ok"]
    assert_equal "tx_rejected", result["code"],
                 "the board branches on this code to open the cosign-rejected modal; flattened to a " \
                 "message it shows a raw error instead, on a flow where the user did nothing wrong"
    assert_equal "tx_rejected", result.dig("blockerData", "code"),
                 "the WHOLE payload travels, not just the code — the same rule prepare's blockers follow"
  end

  # A success carries no code, so a board that branches on one cannot misread a
  # completed entry as a refusal.
  test "a successful complete carries no refusal code" do
    result = run_js("window.tmCompleteContestEntry({ contestId: 1, csrfToken: 'T' }, " \
                    "{ signedTransaction: 'B58<1>' }, { ptx_slug: 'p' })")

    assert result["ok"]
    assert_equal "SIG", result.dig("value", "tx_signature")
  end

  # --- a failed prepare is often a BLOCKER, not an error ---------------------

  # The inline path routes a failed prepare through _handleBlockerResponse, so
  # "you need funds" opens the funds panel rather than printing itself. The
  # redirect path prepares in here, where that method is out of reach, so the
  # payload has to ride the Error back to the board's catch. Flattening it to a
  # string is what collapsed every blocker to raw text on a phone.
  test "prepare carries the server's blocker payload on the error it throws" do
    body = { "success" => false, "error" => "You need USDC to enter",
             "blocker" => "no_funding", "required_usdc" => 5 }
    out = run_js("window.tmPrepareContestEntry({ contestId: 1, csrfToken: 'x', currency: 'usdc' })",
                 body: body)

    refute out["ok"], "a failed prepare must still throw"
    assert_equal "You need USDC to enter", out["message"]
    assert_equal "no_funding", out.dig("blockerData", "blocker"),
                 "the board's catch reads blockerData to pick the right panel"
    assert_equal 5, out.dig("blockerData", "required_usdc"),
                 "the WHOLE payload travels, not just the blocker name"
  end

  # The 401 shape is not a blocker — authedFetch has already surfaced the login
  # modal, and attaching a payload that does not exist would send the catch
  # looking for a panel to open.
  test "a 401 throws without a blocker payload" do
    out = run_js("window.tmPrepareContestEntry({ contestId: 1, csrfToken: 'x', currency: 'usdc' })",
                 fetch: :unauthorized)

    refute out["ok"]
    assert_nil out["blockerData"], "a session expiry is not a blocker panel"
  end

  # --- the callback document has no authedFetch ------------------------------
  #
  # THE DEFECT THESE EXIST FOR, and the reason the rest of this file could not
  # see it: every other case here SUPPLIES window.authedFetch. On the real
  # callback page it does not exist yet — it ships in a deferred importmap
  # module, while studio-engine dispatches from a bare inline script during body
  # parse and wallet_ops calls complete() synchronously. A direct
  # window.authedFetch(...) therefore threw a TypeError AFTER the user approved
  # in Phantom, with the journal already consumed by take(). Found in review of
  # PR 632, on the second lap.

  test "prepare completes on a document that has no authedFetch" do
    out = run_js("window.tmPrepareContestEntry({ contestId: 1, csrfToken: 'x', currency: 'usdc' })",
                 fetch: :no_authed_fetch)

    assert out["ok"], "prepare must not throw where authedFetch is absent: #{out['message']}"
    assert_equal "ptx-1", out.dig("value", "ptx_slug")
  end

  test "complete completes on a document that has no authedFetch" do
    out = run_js("window.tmCompleteContestEntry({ contestId: 1, csrfToken: 'x' }, " \
                 "{ signedTransaction: 'B58<1,2,3>' }, { entry_id: 7, entry_pda: 'PDA', ptx_slug: 'ptx-1' })",
                 fetch: :no_authed_fetch)

    assert out["ok"], "complete is the leg that runs on the callback page: #{out['message']}"
    assert_equal "SIG", out.dig("value", "tx_signature")
  end

  # authedFetch answers FALSY on a 401; plain fetch answers a 401 Response. Both
  # handlers branch on `if (!resp)`, so the fallback has to speak the same
  # dialect or an expired session reads as a successful prepare.
  test "the fallback normalises a 401 to the falsy shape authedFetch uses" do
    out = run_js("window.tmPrepareContestEntry({ contestId: 1, csrfToken: 'x', currency: 'usdc' })",
                 fetch: :no_authed_fetch_401)

    refute out["ok"], "a 401 through the fallback must throw, not resolve"
    assert_match(/session expired/i, out["message"])
  end

  test "authedFetch is still preferred when the document does have it" do
    out = run_js("window.tmPrepareContestEntry({ contestId: 1, csrfToken: 'x', currency: 'usdc' })")

    assert out["ok"]
    assert_equal "/contests/1/prepare_entry", out["calls"].first[1],
                 "the authed path must still be the one taken where it exists"
  end

  # --- the outstanding prepared row ----------------------------------------
  #
  # WHY THE LEDGER EXISTS, and it is not bookkeeping for its own sake.
  # prepare_entry MINTS a PreparedTransaction carrying a fresh blockhash. If the
  # user dismisses the wallet prompt, the board retires that row before offering
  # "Try Again", so the retry builds new bytes instead of racing an expiring
  # blockhash. The board used to hold the slug in a local because it ran the
  # prepare POST itself; now this handler does, on both transports — and
  # walletOps does not hand `prepared` back when the signing hop rejects, so the
  # slug is on neither the error nor a local. The window record is the seam, and
  # its two edges are what these tests pin: SET when a row is minted, CLEARED the
  # moment complete() begins, because after signing the attempt belongs to
  # on-chain recovery and retiring the row then would be wrong.
  #
  # The e2e (free_entry_spend_mirror.spec.js) drives the whole recovery in a
  # browser; these own the two edges, which no browser assertion can isolate.

  test "prepare records the prepared row a rejected signature must retire" do
    out = run_js(<<~JS)
      (async function () {
        var state = await window.tmPrepareContestEntry({ contestId: 12, csrfToken: 'T', currency: 'usdc' });
        return { state: state, ledger: window.tmOutstandingEntryPrepare };
      })()
    JS

    assert out["ok"], out["message"]
    assert_equal({ "ptxSlug" => "ptx-1", "contestId" => 12 }, out["value"]["ledger"],
                 "without this the board cannot retire the row it just spent, so a " \
                 "dismissed wallet prompt strands a PreparedTransaction and the retry " \
                 "races its blockhash")
  end

  test "a failed prepare records nothing to retire" do
    out = run_js(<<~JS, body: { "success" => false, "error" => "Not enough USDC" })
      (async function () {
        try { await window.tmPrepareContestEntry({ contestId: 12, csrfToken: 'T', currency: 'usdc' }); }
        catch (e) { /* the refusal is asserted elsewhere */ }
        return { ledger: window.tmOutstandingEntryPrepare || null };
      })()
    JS

    assert out["ok"], out["message"]
    assert_nil out["value"]["ledger"],
               "the server minted no row when it refused, so recording one would send the " \
               "board to discard_prepared_entry with a slug that never existed"
  end

  test "complete clears the outstanding row before any branch can throw" do
    # DRIVEN THROUGH THE THROWING BRANCH ON PURPOSE. A clear placed after the
    # sign-only guard would leave the row recorded on exactly the path that
    # reaches it — and the board would then offer a retry for an entry whose
    # transaction a wallet had already broadcast.
    out = run_js(<<~JS)
      (async function () {
        window.tmOutstandingEntryPrepare = { ptxSlug: 'ptx-1', contestId: 12 };
        var threw = null;
        try {
          await window.tmCompleteContestEntry({ contestId: 12, csrfToken: 'T' },
                                              { signedTransaction: null, signature: 'SIG' }, {});
        } catch (e) { threw = e.message; }
        return { threw: threw, ledger: window.tmOutstandingEntryPrepare };
      })()
    JS

    assert out["ok"], out["message"]
    assert_match(/broadcast this entry instead of signing/i, out["value"]["threw"],
                 "the sign-only guard must still refuse a broadcast")
    assert_nil out["value"]["ledger"],
               "the signing hop is over once complete() runs — anything failing from here " \
               "belongs to on-chain recovery, never to a discard-and-retry"
  end

  # --- blockers on the RETURN leg -------------------------------------------

  test "complete carries the server's blocker payload on the error it throws" do
    # THE PREPARE HALF OF THIS WAS FIXED IN PR 632 AND THE CONFIRM HALF WAS NOT,
    # which only mattered once the inline call site moved behind walletOps: it
    # used to route a failed confirm through _handleBlockerResponse itself. A
    # flattened string here collapses every funds/age/first-name panel to raw
    # text — the same regression, one hop later.
    out = run_js(<<~JS, body: { "success" => false, "error" => "Entry token already spent", "code" => "no_funding" })
      window.tmCompleteContestEntry({ contestId: 12, csrfToken: 'T' },
                                    { signedTransaction: 'B58<1,2,3>' },
                                    { entry_id: 7, entry_pda: 'PDA', ptx_slug: 'ptx-1' })
    JS

    refute out["ok"], "a server refusal must reject"
    assert_equal "no_funding", out["blockerData"]["code"],
                 "the payload must ride the Error — the board's catch is the only place " \
                 "_handleBlockerResponse can be reached from"
  end

  # --- what the user is asked to approve ------------------------------------
  #
  # token_funded is the SERVER's decision, echoed back by prepare_entry for
  # exactly this copy, and it is only knowable here — walletOps offers no hook
  # between prepare and the signing hop, so no call site can paint it.

  test "a token-funded entry never asks the user to approve a transfer" do
    out = run_js(<<~JS)
      (async function () {
        var shown = [];
        window.Alpine = { store: function () { return { show: function (t, b) { shown.push([t, b]); } }; } };
        await window.tmPrepareContestEntry({ contestId: 12, csrfToken: 'T', currency: 'usdc' });
        return shown;
      })()
    JS

    assert out["ok"], out["message"]
    assert_equal [["Sign Transaction", "Approve your free entry in your wallet..."]], out["value"],
                 "the server built enter_contest_with_token, so naming a USDC transfer here " \
                 "contradicts the Hold for Free Entry button the user just pressed"
  end

  test "a paid entry names the currency the caller actually chose" do
    paid = { "success" => true, "serialized_tx" => "AQID", "ptx_slug" => "ptx-1",
             "entry_id" => 7, "entry_pda" => "PDA", "token_funded" => false }
    out = run_js(<<~JS, body: paid)
      (async function () {
        var shown = [];
        window.Alpine = { store: function () { return { show: function (t, b) { shown.push([t, b]); } }; } };
        await window.tmPrepareContestEntry({ contestId: 12, csrfToken: 'T', currency: 'usdt' });
        return shown;
      })()
    JS

    assert out["ok"], out["message"]
    assert_equal [["Sign Transaction", "Approve the USDT transfer in your wallet..."]], out["value"],
                 "the currency decided at the call site, the prompt copy, and the transfer " \
                 "the server built all have to name the same token"
  end

  test "the server's confirm leg is narrated, not left on the signing copy" do
    # confirm BLOCKS on send_and_confirm; unpainted, the card sits on the signing copy.
    out = run_js(<<~JS)
      (async function () {
        var shown = [];
        window.Alpine = { store: function () { return { show: function (t, b) { shown.push([t, b]); } }; } };
        await window.tmCompleteContestEntry({ contestId: 12, csrfToken: 'T' },
          { signedTransaction: 'B58<1,2,3>' }, { ptx_slug: 'p1', entry_id: 7, entry_pda: 'PDA' });
        return shown;
      })()
    JS
    assert out["ok"], out["message"]
    assert_equal [["Confirming Onchain", "Cosigning and submitting to Solana..."]], out["value"],
                 "the wallet is done and the server is not — say so, or the user reopens the wallet"
  end

  test "a document without Alpine still prepares an entry" do
    # THE ABSENT-CAPABILITY RULE. Copy is a courtesy; an entry is not. This
    # handler is registered on EVERY page, including the wallet callback.
    out = run_js("window.tmPrepareContestEntry({ contestId: 12, csrfToken: 'T', currency: 'usdc' })")

    assert out["ok"], out["message"]
    assert_equal "B58<1,2,3>", out["value"]["transaction"]
  end
end
