require "test_helper"

# [unit] selectionBoard() — the board answers a hold ONCE.
#
# WHAT THIS TIER OWNS. init() listens on window and document, which outlive a
# Turbo visit; the component does not. Every board the tab builds runs init()
# again, so a board that leaves its listeners behind keeps answering
# 'hold-confirm-entry' from the page that replaced it, and one hold posts
# /enter once per board (task board-hold-enters-once). This drives the real
# script from the partial in node, with window, document and Alpine stubbed at
# the seam, and counts listeners and requests. The browser journey is
# e2e/board_hold_enters_once.spec.js.
class BoardHoldListenerJsTest < ActiveSupport::TestCase
  include BoardScriptHarness

  BOARD = Rails.root.join("app/views/contests/_turf_totals_board.html.erb")

  # The selectionBoard script: the partial's last <script> block. Its ERB
  # interpolations are JSON string literals, so each becomes one here.
  def board_script
    src = File.read(BOARD)
    open_tag = src.rindex("<script>")
    body = src[(open_tag + "<script>".length)...src.index("</script>", open_tag)]
    assert_includes body, "window.selectionBoard = function", "the last script block is the board"
    body.gsub(/<%=.*?%>/m, '"erb"')
  end

  def run_js(body) = run_board_js(board_script, body)

  test "the board registers its hold listener once per page lifetime" do
    out = run_js(<<~JS)
      var first = newBoard();
      var one = #{census_js};
      // The page the tab comes Back to: a second board, with the first never told it left.
      var second = newBoard();
      return { one: one, two: #{census_js}, firstChannelClosed: channels[0].closed, secondChannelClosed: channels[1].closed };
    JS

    assert_nil out["error"], out.inspect
    BOARD_EVENTS.each do |key|
      assert_equal 1, out["one"][key], "a fresh board listens once on #{key}"
      assert_equal 1, out["two"][key], "the board before it stopped listening on #{key}"
    end
    assert_equal true, out["firstChannelClosed"], "the board that left closed its tokens channel"
    assert_equal false, out["secondChannelClosed"], "the live board keeps its own"
  end

  test "Alpine's destroy removes every listener the board added" do
    out = run_js(<<~JS)
      var board = newBoard();
      board.destroy();
      board.destroy(); // twice is safe
      return { census: #{census_js}, beforeCache: listening('document:turbo:before-cache'), closed: channels[0].closed, handle: window.__turfBoardTeardown };
    JS

    assert_nil out["error"], out.inspect
    BOARD_EVENTS.each { |key| assert_equal 0, out["census"][key], "#{key} survived destroy()" }
    assert_equal 0, out["beforeCache"]
    assert_equal true, out["closed"]
    assert_nil out["handle"], "a board that is gone leaves no teardown on window"
  end

  test "turbo:before-cache removes them too, so the snapshot's board starts alone" do
    out = run_js(<<~JS)
      newBoard();
      var armed = listening('document:turbo:before-cache');
      fire('document:turbo:before-cache');
      return { armed: armed, census: #{census_js}, beforeCache: listening('document:turbo:before-cache') };
    JS

    assert_nil out["error"], out.inspect
    assert_equal 1, out["armed"]
    BOARD_EVENTS.each { |key| assert_equal 0, out["census"][key], "#{key} survived turbo:before-cache" }
    assert_equal 0, out["beforeCache"]
  end

  test "one hold after a revisit sends one enter request" do
    out = run_js(<<~JS)
      newBoard();
      newBoard();
      fire('window:hold-confirm-entry');
      await tick(); await tick();
      return { enters: enters.length };
    JS

    assert_nil out["error"], out.inspect
    assert_equal 1, out["enters"]
  end

  # The window a managed wallet's double complete walks through: confirmEntry()
  # awaits the funding pre-check BEFORE it sets `submitting`, so its own
  # re-entry guard is still open when a second complete arrives in that wait.
  test "a second confirm while the first is in flight is ignored" do
    out = run_js(<<~JS)
      newBoard();
      fire('window:hold-funding-check');   // the hold starts: pre-check opens
      fire('window:hold-confirm-entry');   // the hold completes
      fire('window:hold-confirm-entry');   // and completes again, same tick
      await tick();
      funding({ fundable: true });
      await tick(); await tick();
      var afterTwo = enters.length;
      fire('window:hold-confirm-entry');   // a third, with /enter still open
      await tick(); await tick();
      return { afterTwo: afterTwo, afterThree: enters.length };
    JS

    assert_nil out["error"], out.inspect
    assert_equal 1, out["afterTwo"], "two completes inside the pre-check wait sent one request"
    assert_equal 1, out["afterThree"], "a complete while /enter is open sent nothing"
  end

  test "the in-flight flag clears when a confirm settles, so the next hold works" do
    out = run_js(<<~JS)
      var board = newBoard();
      var calls = 0;
      var settle;
      board.confirmEntry = function () { calls += 1; return new Promise(function (resolve, reject) { settle = { resolve: resolve, reject: reject }; }); };
      fire('window:hold-confirm-entry'); await tick();
      fire('window:hold-confirm-entry'); await tick();
      var whileOpen = calls;
      settle.resolve(); await tick();
      fire('window:hold-confirm-entry'); await tick();
      var afterResolve = calls;
      settle.reject(new Error('stopped')); await tick();
      fire('window:hold-confirm-entry'); await tick();
      return { whileOpen: whileOpen, afterResolve: afterResolve, afterReject: calls };
    JS

    assert_nil out["error"], out.inspect
    assert_equal 1, out["whileOpen"]
    assert_equal 2, out["afterResolve"], "a confirm that finished does not block the next hold"
    assert_equal 3, out["afterReject"], "nor does one that threw"
  end
end
