require "test_helper"

# [unit] No string hook reaches the engine's hold button from this app.
#
# studio/_hold_button takes six locals that are JavaScript source: it writes
# each to a data-* attribute and the engine evaluates the text. The board
# answers the button's hold-button:* events instead, so no caller passes one.
# This reads every caller in the source, and the page a browser is sent.
class HoldButtonEventHooksTest < ActionDispatch::IntegrationTest
  # Local name => the attribute the partial writes it to.
  STRING_HOOKS = {
    "guard" => "data-guard", "on_hold_start" => "data-on-hold-start", "validate" => "data-validate",
    "early_action" => "data-early-action", "early_action_guard" => "data-early-action-guard",
    "on_success" => "data-on-success"
  }.freeze

  CALLERS = %w[
    app/views/contests/_turf_totals_board.html.erb
    app/views/modals/auth/_paypal_tokens.html.erb
    app/views/modals/auth/_tokens.html.erb
  ].freeze

  BOARD = "app/views/contests/_turf_totals_board.html.erb".freeze
  SOURCES = Dir[Rails.root.join("{app,lib}/**/*.{erb,rb,js,haml,slim}").to_s].freeze

  # Every render of the partial: [relative path, the call up to its closing tag].
  def hold_button_renders
    SOURCES.flat_map do |path|
      File.read(path).scan(%r{render[\s(]+(?:partial:\s*)?["']studio/hold_button["'].*?%>}m).map do |call|
        [Pathname(path).relative_path_from(Rails.root).to_s, call]
      end
    end
  end

  test "the scan finds every caller of the partial" do
    renders = hold_button_renders

    assert_equal CALLERS, renders.map(&:first).uniq.sort
    assert_equal 4, renders.size, "the cart's two buttons and the token modal's two"

    mentions = SOURCES.count { |path| File.read(path).match?(%r{["']studio/hold_button["']}) }
    assert_equal CALLERS.size, mentions, "a file names the partial in a way the scan does not read"
  end

  test "no caller passes a JavaScript string local" do
    hold_button_renders.each do |path, call|
      STRING_HOOKS.each_key do |local|
        refute_match(/(?<![\w])#{local}:/, call, "#{path} passes #{local}: to studio/hold_button")
      end
    end
  end

  test "no source file writes a string hook attribute by hand" do
    SOURCES.each do |path|
      source = File.read(path)
      STRING_HOOKS.each_value do |attribute|
        refute_match(/#{attribute}(?![\w-])/, source, "#{path} writes #{attribute}")
      end
    end
  end

  # The names are the pinned engine's own: every data-* key its hooks module
  # evaluates is one this test refuses.
  test "the refused attributes are the ones the pinned engine evaluates" do
    hooks = File.join(Gem.loaded_specs.fetch("studio-engine").full_gem_path, "app/javascript/studio/hold_button_hooks.js")
    skip "the engine no longer ships string hooks" unless File.exist?(hooks) && File.read(hooks).include?("button.dataset.")

    read = File.read(hooks).scan(/button\.dataset\.(\w+)/).flatten.uniq - ["holdId"]
    attributes = read.map { |key| "data-#{key.gsub(/([A-Z])/) { "-#{$1.downcase}" }}" }

    assert_equal STRING_HOOKS.values.sort, attributes.sort
  end

  test "the contest page carries hold buttons with no string hook on them" do
    get contest_path(contests(:one))
    assert_response :success
    buttons = response.body.scan(/<button class="hold-btn".*?>/m)

    assert_operator buttons.size, :>=, 2, "the page renders the cart's hold buttons"
    assert_equal %w[desktop mobile], buttons.map { |tag| tag[/data-hold-id="([^"]*)"/, 1] }.first(2)
    buttons.each do |tag|
      STRING_HOOKS.each_value { |attribute| refute_match(/#{attribute}(?![\w-])/, tag, "a hold button carries #{attribute}") }
    end
    assert_empty response.body.scan(/#{Regexp.union(STRING_HOOKS.values)}=/), "a string hook attribute is on the page"
  end

  # A hold_id the board does not answer would complete and enter nothing.
  test "the board answers every hold_id a caller renders" do
    ids = hold_button_renders.map { |_, call| call[/hold_id:\s*"([^"]+)"/, 1] }
    assert_equal %w[desktop mobile tokens-modal tokens-modal], ids.sort

    script = File.read(Rails.root.join(BOARD))
    assert_includes script, "var BOARD_HOLDS = ['desktop', 'mobile'], MODAL_HOLD = 'tokens-modal'"
    %w[guard start validate early success].each do |name|
      assert_includes script, "listen(document, 'hold-button:#{name}', function (e) {"
    end
  end

  # The timings the string locals carried stay on the buttons.
  test "the cart's buttons keep their validate and early-action times" do
    get contest_path(contests(:one))
    buttons = response.body.scan(/<button class="hold-btn".*?>/m).first(2)

    buttons.each do |tag|
      assert_includes tag, %(data-duration="2000")
      assert_includes tag, %(data-validate-at="750")
      assert_includes tag, %(data-early-action-at="1500")
    end
  end
end
