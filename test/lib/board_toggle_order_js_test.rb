require "test_helper"

# [unit] selectionBoard#toggleSelection — picks made faster than the server
# answers all stay in the cart (task ci-cause-turf-monster-e2e-glass-surfaces-spec-js).
#
# Each pick POSTs toggle_selection and the board adopts the answer as the truth.
# The answer is the cart as it stood when THAT request ran. With the POSTs in
# flight together, an earlier pick's answer could land after a later pick's, and
# adopting it last threw the later picks away (CI: the slip fell from 5 / 6 to
# 3 / 6). This drives the real script from the partial in node against a fake
# server that applies each POST when it arrives and holds every answer, then
# delivers the answers newest first: the order that broke the board. The
# browser journey is e2e/picks_answer_in_order.spec.js.
class BoardToggleOrderJsTest < ActiveSupport::TestCase
  include BoardScriptHarness

  BOARD = Rails.root.join("app/views/contests/_turf_totals_board.html.erb")

  def board_script
    src = File.read(BOARD)
    open_tag = src.rindex('<script nonce="<%= content_security_policy_nonce %>">')
    body = src[(open_tag + '<script nonce="<%= content_security_policy_nonce %>">'.length)...src.index("</script>", open_tag)]
    assert_includes body, "window.selectionBoard = function", "the last script block is the board"
    body.gsub(/<%=.*?%>/m, '"erb"')
  end

  # The fake server: a POST is applied when it is sent, and its answer (the cart
  # as of that moment) waits in `held` until the test delivers it.
  FAKE_SERVER = <<~JS.freeze
    var server = {};
    var held = [];
    var inFlight = 0, mostInFlight = 0;
    window.authedFetch = function (url, options) {
      var id = String(JSON.parse(options.body).matchup_id);
      if (server[id]) delete server[id]; else server[id] = true;
      var answer = { selections: Object.assign({}, server) };
      inFlight += 1; mostInFlight = Math.max(mostInFlight, inFlight);
      return new Promise(function (resolve) {
        held.push(function () {
          inFlight -= 1;
          resolve({ ok: true, json: function () { return Promise.resolve(answer); } });
        });
      });
    };
    // Deliver the newest held answer, let the board take it, repeat until none is left.
    async function deliverNewestFirst() {
      for (var guard = 0; guard < 50; guard += 1) {
        await tick();
        if (!held.length) return;
        held.pop()();
        await tick();
      }
    }
  JS

  test "an earlier pick's late answer does not drop the picks after it" do
    out = run_board_js(board_script, <<~JS)
      #{FAKE_SERVER}
      var board = newBoard();
      ['11', '22', '33'].forEach(function (id) { board.toggleSelection(id); });
      var shownAtOnce = Object.keys(board.selections).sort();
      await deliverNewestFirst();
      return { shownAtOnce: shownAtOnce, shown: Object.keys(board.selections).sort(), order: board.selectionOrder,
               server: Object.keys(server).sort(), mostInFlight: mostInFlight };
    JS

    assert_nil out["error"], out.inspect
    assert_equal %w[11 22 33], out["shownAtOnce"], "each pick shows at once, before any answer"
    assert_equal %w[11 22 33], out["server"], "the server holds all three picks"
    assert_equal %w[11 22 33], out["shown"], "the cart lost picks to an earlier pick's late answer"
    assert_equal %w[11 22 33], out["order"]
    assert_equal 1, out["mostInFlight"], "a toggle went out before the one ahead of it was answered"
  end

  test "a pick the server refuses mid-queue still leaves the cart the server holds" do
    out = run_board_js(board_script, <<~JS)
      #{FAKE_SERVER}
      var serve = window.authedFetch;
      window.authedFetch = function (url, options) {
        if (String(JSON.parse(options.body).matchup_id) !== '22') return serve(url, options);
        return Promise.resolve({ ok: false, json: function () { return Promise.resolve({ error: 'Game has already started' }); } });
      };
      var errors = [];
      var board = newBoard();
      board.showError = function (message) { errors.push(message); };
      ['11', '22', '33'].forEach(function (id) { board.toggleSelection(id); });
      await deliverNewestFirst();
      return { shown: Object.keys(board.selections).sort(), server: Object.keys(server).sort(), errors: errors };
    JS

    assert_nil out["error"], out.inspect
    assert_equal %w[11 33], out["server"]
    assert_equal %w[11 33], out["shown"], "the cart shows what the server holds"
    assert_equal ["Game has already started"], out["errors"], "the refusal still says so"
  end
end
