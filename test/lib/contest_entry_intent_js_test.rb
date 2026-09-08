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
  PARTIAL = Rails.root.join("app/views/contests/_turf_totals_board.html.erb")

  # Pull both handlers out of the view verbatim.
  def handlers_source
    src = File.read(PARTIAL)
    # THE DEFINITION, not the first mention. The intent registration above it
    # CALLS window.tmPrepareContestEntry(ctx), so a bare index() lands mid-object
    # and extracts syntactically broken JS.
    start = src.index("window.tmPrepareContestEntry = async function")
    finish = src.index("// selectionBoard")
    assert start, "could not find tmPrepareContestEntry in the partial"
    assert finish && finish > start, "could not bound the handler block"
    src[start...finish]
  end

  # `fetch:` describes what authedFetch answers — :ok, :unauthorized (falsy, the
  # 401 shape), or a hash body with success:false.
  def run_js(script, fetch: :ok, body: nil)
    fetch_js =
      case fetch
      when :unauthorized then "window.authedFetch = function () { calls.push(['fetch', arguments[0], arguments[1]]); return Promise.resolve(null); };"
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
        catch (e) { RESULT = { ok: false, message: e.message }; }
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
end
