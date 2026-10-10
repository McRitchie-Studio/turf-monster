require "test_helper"

# [unit] selectionBoard() — the board answers a hold ONCE.
#
# WHAT THIS TIER OWNS. init() listens on window and document, which outlive a
# Turbo visit; the component does not. Every board the tab builds runs init()
# again, so a board that leaves its listeners behind keeps answering the hold
# button's events from the page that replaced it, and one hold posts /enter
# once per board (task board-hold-enters-once). This drives the real
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

  def run_js(body, **options) = run_board_js(board_script, body, **options)

  # One completed hold on the cart's button: the event, then the settle the
  # board waits before it confirms.
  COMPLETE = "hold('success', 'desktop'); advance(500);".freeze

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

  # Turbo also caches on a history move it renders nothing for (a fragment
  # change). The board is still on the page, so its hold must still answer.
  test "a cache with no Turbo visit in flight leaves the board listening" do
    out = run_js(<<~JS)
      newBoard();
      window.Turbo = { navigator: {} };
      fire('document:turbo:before-cache');
      var stayed = #{census_js};
      window.Turbo.navigator.currentVisit = {};
      fire('document:turbo:before-cache');
      return { stayed: stayed, left: #{census_js} };
    JS

    assert_nil out["error"], out.inspect
    BOARD_EVENTS.each { |key| assert_equal 1, out["stayed"][key], "#{key} was dropped by a cache that rendered nothing" }
    BOARD_EVENTS.each { |key| assert_equal 0, out["left"][key], "#{key} survived a real visit's cache" }
  end

  test "one hold after a revisit sends one enter request" do
    out = run_js(<<~JS)
      newBoard();
      newBoard();
      #{COMPLETE}
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
      hold('start', 'desktop');            // the hold starts: pre-check opens
      hold('success', 'desktop');          // the hold completes
      hold('success', 'desktop');          // and completes again, same tick
      advance(500);
      await tick();
      funding({ fundable: true });
      await tick(); await tick();
      var afterTwo = enters.length;
      #{COMPLETE}                           // a third, with /enter still open
      await tick(); await tick();
      return { afterTwo: afterTwo, afterThree: enters.length };
    JS

    assert_nil out["error"], out.inspect
    assert_equal 1, out["afterTwo"], "two completes inside the pre-check wait sent one request"
    assert_equal 1, out["afterThree"], "a complete while /enter is open sent nothing"
  end

  # The wallet runner's onStranded frees the board (submitting = false) for a
  # confirm whose request may never answer. The flag must not outlive that.
  test "a board freed while its request is still open takes the next hold" do
    out = run_js(<<~JS)
      var board = newBoard();
      #{COMPLETE}
      await tick(); await tick();
      var first = enters.length;            // /enter is open and never answers
      board.submitting = false;             // the board is handed its controls back
      #{COMPLETE}
      await tick(); await tick();
      return { first: first, afterFreed: enters.length };
    JS

    assert_nil out["error"], out.inspect
    assert_equal 1, out["first"]
    assert_equal 2, out["afterFreed"], "the hold after a stranded confirm reached /enter"
  end

  test "the in-flight flag clears when a confirm settles, so the next hold works" do
    out = run_js(<<~JS)
      var board = newBoard();
      var calls = 0;
      var settle;
      board.confirmEntry = function () { calls += 1; return new Promise(function (resolve, reject) { settle = { resolve: resolve, reject: reject }; }); };
      #{COMPLETE} await tick();
      #{COMPLETE} await tick();
      var whileOpen = calls;
      settle.resolve(); await tick();
      #{COMPLETE} await tick();
      var afterResolve = calls;
      settle.reject(new Error('stopped')); await tick();
      #{COMPLETE} await tick();
      return { whileOpen: whileOpen, afterResolve: afterResolve, afterReject: calls };
    JS

    assert_nil out["error"], out.inspect
    assert_equal 1, out["whileOpen"]
    assert_equal 2, out["afterResolve"], "a confirm that finished does not block the next hold"
    assert_equal 3, out["afterReject"], "nor does one that threw"
  end

  # ── The hold button's events (task turf-hold-button-uses-events) ──────────
  # Each test below is one answer the board gives the engine's hold button.

  test "a press is refused until the cart is full, on the cart's buttons only" do
    out = run_js(<<~JS)
      var board = newBoard();
      var short = { desktop: hold('guard', 'desktop').defaultPrevented, mobile: hold('guard', 'mobile').defaultPrevented,
                    modal: hold('guard', 'tokens-modal').defaultPrevented, other: hold('guard', 'someone-elses').defaultPrevented };
      board.selections = { 1: 'a', 2: 'a', 3: 'a', 4: 'a', 5: 'a', 6: 'a' };
      var count = board.selectionCount;
      return { short: short, count: count, full: { desktop: hold('guard', 'desktop').defaultPrevented, mobile: hold('guard', 'mobile').defaultPrevented } };
    JS

    assert_nil out["error"], out.inspect
    assert_equal({ "desktop" => true, "mobile" => true, "modal" => false, "other" => false }, out["short"])
    assert_equal 6, out["count"], "the fixture filled the cart"
    assert_equal({ "desktop" => false, "mobile" => false }, out["full"], "a full cart lets the press through")
  end

  test "a hold that starts on the cart opens the funding pre-check" do
    out = run_js(<<~JS)
      newBoard();
      hold('start', 'tokens-modal'); hold('start', 'someone-elses');
      var others = fundingChecks.length;
      hold('start', 'desktop'); hold('start', 'mobile');
      return { others: others, cart: fundingChecks.length };
    JS

    assert_nil out["error"], out.inspect
    assert_equal 0, out["others"], "only the cart's buttons open the pre-check"
    assert_equal 2, out["cart"]
  end

  test "validation is the board's answer, handed to the button to wait on" do
    out = run_js(<<~JS)
      var board = newBoard();
      var verdict = true;
      board.runHoldValidations = function () { return Promise.resolve(verdict); };
      var yes = hold('validate', 'desktop');
      verdict = false;
      var no = hold('validate', 'mobile');
      var modal = hold('validate', 'tokens-modal');
      return { yes: await yes.answers[0], no: await no.answers[0], waited: [yes.answers.length, no.answers.length], modal: modal.answers.length };
    JS

    assert_nil out["error"], out.inspect
    assert_equal [1, 1], out["waited"]
    assert_equal true, out["yes"]
    assert_equal false, out["no"], "a false answer reaches the button, which aborts the hold"
    assert_equal 0, out["modal"], "the token modal's button is not validated"
  end

  test "the early action is taken only by a wallet session on an on-chain contest" do
    cases = { "managed" => [true, false], "offchain" => [false, true], "wallet_onchain" => [true, true] }
    cases.each do |name, (onchain, web3)|
      out = run_js(<<~JS, config: DEFAULT_CONFIG.merge(contestOnchain: onchain))
        var board = newBoard();
        var calls = 0;
        board.confirmEntry = function () { calls += 1; return new Promise(function () {}); };
        session.isWeb3 = #{web3};
        var early = hold('early', 'desktop');
        var modal = hold('early', 'tokens-modal');
        await tick();
        return { taken: early.defaultPrevented, modal: modal.defaultPrevented, calls: calls };
      JS

      assert_nil out["error"], out.inspect
      taken = name == "wallet_onchain"
      assert_equal taken, out["taken"], "#{name}: the hold #{taken ? 'is taken over' : 'runs to its end'}"
      assert_equal (taken ? 1 : 0), out["calls"], "#{name}: confirmEntry calls"
      assert_equal false, out["modal"], "#{name}: the token modal's button has no early action"
    end
  end

  test "a completed hold keeps the button and enters once, half a second later" do
    out = run_js(<<~JS)
      newBoard();
      var done = hold('success', 'desktop');
      advance(499); await tick(); await tick();
      var before = enters.length;
      advance(1); await tick(); await tick();
      return { owned: done.defaultPrevented, before: before, after: enters.length };
    JS

    assert_nil out["error"], out.inspect
    assert_equal true, out["owned"], "the board owns the button's state from the complete"
    assert_equal 0, out["before"], "nothing is sent inside the settle"
    assert_equal 1, out["after"]
  end

  test "each of the three buttons enters, and a button that is not the board's does not" do
    %w[desktop mobile tokens-modal].each do |id|
      out = run_js(<<~JS)
        newBoard();
        var done = hold('success', #{id.to_json});
        advance(500); await tick(); await tick();
        return { owned: done.defaultPrevented, enters: enters.length };
      JS

      assert_nil out["error"], out.inspect
      assert_equal true, out["owned"], id
      assert_equal 1, out["enters"], "#{id} sent one enter request"
    end

    out = run_js(<<~JS)
      newBoard();
      var done = hold('success', 'someone-elses');
      advance(500); await tick(); await tick();
      return { owned: done.defaultPrevented, enters: enters.length };
    JS

    assert_nil out["error"], out.inspect
    assert_equal false, out["owned"], "a hold the board does not know keeps its own success face"
    assert_equal 0, out["enters"]
  end

  test "a second, separate hold enters once more" do
    out = run_js(<<~JS)
      var board = newBoard();
      #{COMPLETE}
      await tick(); await tick();
      var first = enters.length;
      board.submitting = false;             // the first request answered
      #{COMPLETE}
      await tick(); await tick();
      return { first: first, second: enters.length };
    JS

    assert_nil out["error"], out.inspect
    assert_equal 1, out["first"]
    assert_equal 2, out["second"]
  end

  # The token modal drops its button from the page when it closes.
  test "a button that left the page inside the settle enters nothing" do
    out = run_js(<<~JS)
      newBoard();
      var button = { isConnected: true };
      hold('success', 'tokens-modal', button);
      button.isConnected = false;
      advance(500); await tick(); await tick();
      return { enters: enters.length };
    JS

    assert_nil out["error"], out.inspect
    assert_equal 0, out["enters"]
  end

  test "a board that left inside the settle enters nothing" do
    out = run_js(<<~JS)
      var board = newBoard();
      hold('success', 'desktop');
      board.destroy();
      advance(500); await tick(); await tick();
      return { enters: enters.length };
    JS

    assert_nil out["error"], out.inspect
    assert_equal 0, out["enters"]
  end
end
