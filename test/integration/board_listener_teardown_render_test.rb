require "test_helper"

# [component] The contest page AS RENDERED carries a board that listens once.
#
# test/lib/board_hold_listener_js_test.rb drives the partial's source, with its
# ERB tags swapped for literals. This tier takes the page the server actually
# sends: the script block and the #board-config blob beside it, exactly as a
# browser receives them, and runs that pair in node. What it adds is the seam
# the source test cannot see: that the rendered script parses, reads the
# rendered config, and still leaves one listener per board event after a second
# board is built on the same window (task board-hold-enters-once).
#
# The real Turbo visit and the real hold are e2e/board_hold_enters_once.spec.js.
class BoardListenerTeardownRenderTest < ActionDispatch::IntegrationTest
  include BoardScriptHarness

  setup do
    get contest_path(contests(:one))
    assert_response :success
    @html = response.body
    @script = @html.scan(%r{<script>(.*?)</script>}m).flatten.find { |body| body.include?("window.selectionBoard = function") }
    assert @script, "the contest page renders the selectionBoard script"
    @config = JSON.parse(@html[%r{<script type="application/json" id="board-config">(.*?)</script>}m, 1])
  end

  test "the rendered board leaves one listener per event after a second board is built" do
    out = run_board_js(@script, <<~JS, config: @config)
      newBoard();
      var one = #{census_js};
      newBoard();
      return { one: one, two: #{census_js}, beforeCache: listening('document:turbo:before-cache') };
    JS

    assert_nil out["error"], out.inspect
    BOARD_EVENTS.each do |key|
      assert_equal 1, out["one"][key], "a fresh board listens once on #{key}"
      assert_equal 1, out["two"][key], "the board before it stopped listening on #{key}"
    end
    assert_equal 1, out["beforeCache"], "only the live board waits for turbo:before-cache"
  end

  # The rule the fix rests on: inside init(), window and document are reached
  # through listen(), which records the listener for teardown. A bare
  # addEventListener there is a listener no teardown knows about.
  test "init() registers window and document listeners only through listen()" do
    init = @script[/^    init\(\) \{.*?^    \},$/m]
    assert init, "the board's init() is where its listeners are registered"

    bare = init.scan(/\b(?:window|document)\.addEventListener\(/)
    assert_empty bare, "init() adds a window or document listener that teardownListeners() cannot remove"
    assert_operator init.scan(/\blisten\((?:window|document), '/).size, :>=, BOARD_EVENTS.size + 1
  end

  test "the markup the hold buttons and the root carry is the markup they carried" do
    assert_includes @html, %(@turbo:before-cache.window="persistCartToConfig()")
    assert_includes @html, %(data-on-success="window.dispatchEvent(new CustomEvent(&#39;hold-confirm-entry&#39;))")
  end
end
