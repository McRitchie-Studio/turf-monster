require "test_helper"
require "open3"
require "json"

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

  # `body` runs with: newBoard() (a board Alpine has built and init()ed),
  # listening(key), fire(key), enters (every /enter request), funding (resolve
  # the open pre-check), channels (every BroadcastChannel opened).
  def run_js(body)
    script = <<~JS
      global.window = global;
      global.console = { log: function () {}, warn: function () {}, error: function () {} };

      // Every listener, keyed 'target:event'. removeEventListener REALLY removes.
      var handlers = {};
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
      global.listening = function (key) { return (handlers[key] || []).length; };
      // Copied before iterating: a handler may remove itself or its siblings.
      global.fire = function (key, event) { (handlers[key] || []).slice().forEach(function (cb) { cb(event || {}); }); };

      var cfg = {
        cartSelections: {}, cartSelectionOrder: [], matchupData: {}, firstMatchupIds: [],
        mode: 'create', contestSlug: 'the-contest', entryFeeCents: 1900, picksRequired: 6,
        contestOnchain: false, acceptsUsdt: false, seedsPerLevel: 100
      };
      global.document = {
        getElementById: function (id) { return id === 'board-config' ? { textContent: JSON.stringify(cfg) } : null; },
        querySelector: function () { return null; },
        querySelectorAll: function () { return []; },
        addEventListener: listen('document'),
        removeEventListener: unlisten('document')
      };
      global.addEventListener = listen('window');
      global.removeEventListener = unlisten('window');
      global.location = { search: '', origin: 'https://turf.test', href: 'https://turf.test/contests/the-contest' };
      var storage = { getItem: function () { return null; }, removeItem: function () {}, setItem: function () {} };
      global.sessionStorage = storage;
      global.localStorage = storage;

      var channels = [];
      global.BroadcastChannel = function (name) { this.name = name; this.closed = false; channels.push(this); };
      global.BroadcastChannel.prototype.close = function () { this.closed = true; };

      // A managed-wallet session that holds one entry token: the session the
      // funding pre-check runs for.
      var session = { loggedIn: true, isGuest: false, isWeb3: false, mode: 'web2', tokensAvailable: 1 };
      var modals = { stack: [], current: function () { return null; }, open: function () {}, close: function () {}, advance: function () {} };
      var solanaModal = { show: function () {}, error: function () {}, close: function () {}, success: function () {} };
      global.Alpine = { store: function (n) { return n === 'session' ? session : (n === 'modals' ? modals : solanaModal); } };
      window.eligibilityBlocker = function () { return null; };

      // The two requests a hold makes. The pre-check stays open until the test
      // resolves it; /enter never answers, so the entry stays in flight.
      var enters = [];
      var fundingResolvers = [];
      global.funding = function (answer) { fundingResolvers.splice(0).forEach(function (r) { r(answer); }); };
      window.authedFetch = function (url) {
        if (/check_funding$/.test(url)) {
          return new Promise(function (resolve) {
            fundingResolvers.push(function (answer) { resolve({ ok: true, json: function () { return Promise.resolve(answer); } }); });
          });
        }
        if (/\\/enter$/.test(url)) { enters.push(url); return new Promise(function () {}); }
        return Promise.resolve({ ok: false, status: 404, json: function () { return Promise.resolve({}); } });
      };

      #{board_script}

      global.newBoard = function () { var b = window.selectionBoard(); b.init(); return b; };
      global.tick = function () { return new Promise(function (resolve) { setImmediate(resolve); }); };

      (async function () {
        var out;
        try {
          out = await (async function () { #{body} })();
        } catch (e) {
          out = { error: e.message, stack: String(e.stack).split("\\n").slice(0, 4) };
        }
        process.stdout.write(JSON.stringify(out));
        process.exit(0);
      })();
    JS

    stdout, stderr, status = Open3.capture3("node", "--eval", script)
    assert status.success?, "node failed: #{stderr}"
    JSON.parse(stdout)
  end

  BOARD_EVENTS = %w[window:hold-confirm-entry window:hold-funding-check window:message window:paypal-order-captured].freeze

  def census_js
    "({ #{BOARD_EVENTS.map { |k| "#{k.to_json}: listening(#{k.to_json})" }.join(', ')} })"
  end

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
