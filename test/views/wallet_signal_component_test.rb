require "test_helper"

# `shared/_wallet_signal` — the rendered half of the wallet signal.
#
# WHAT THIS TIER CAN AND CANNOT SEE. It reads the markup the server sends, so it
# proves the component is MOUNTED, that its hooks are there, and that its Alpine
# expressions survive the trip through ERB intact. It cannot see which branch a
# browser paints; that is test/lib/wallet_signal_js_test.rb (the state machine,
# under node) and a Playwright spec (the screen).
#
# THE FAILURE THIS FILE EXISTS FOR, above all others: one double quote inside an
# x-data or x-bind attribute ends the HTML attribute, truncates the expression,
# and kills EVERY binding in the component — while the server-rendered markup
# stays byte-identical and every assert_select in the suite stays green. A dead
# wallet signal on a treasury page looks exactly like a working one that has
# nothing to report. Nokogiri truncates at the stray quote the way Chrome does,
# so reading the attribute back is how it is caught.
class WalletSignalComponentTest < ActionView::TestCase
  # Both variants, so neither can be broken alone.
  VARIANTS = { chip: {}, panel: { variant: :panel } }.freeze

  def render_signal(locals = {})
    render partial: "shared/wallet_signal", locals: locals
    Nokogiri::HTML::DocumentFragment.parse(rendered)
  end

  # EVERY Alpine attribute in the fragment, found by walking the elements rather
  # than by naming the attributes. A named list is a list someone has to
  # remember to widen, and the binding added without widening it is exactly the
  # one that goes unchecked. (`:class` cannot be written as a CSS selector here
  # anyway — Nokogiri rejects the escape.)
  def alpine_attributes(node)
    node.css("*")
        .flat_map { |el| el.attributes.values }
        .select { |attr| attr.name.start_with?("x-", ":", "@") }
  end

  VARIANTS.each do |name, locals|
    test "the #{name} variant mounts with its state readable from the markup" do
      doc = render_signal(locals)
      root = doc.at_css("[data-wallet-signal]")

      refute_nil root, "the #{name} variant rendered no signal at all"
      assert_equal name.to_s, root["data-wallet-signal-variant"]

      # The state is published on the element, not only inside Alpine, so a
      # browser test and an operator's dev tools can both read it.
      assert_includes root[":data-wallet-signal-state"].to_s, "walletSignal",
                      "the #{name} variant must publish its state on the element"

      # Mounted and empty, never inserted: x-show, not template x-if. An
      # inserted status region is not reliably announced, and template x-if
      # mounts as a silent no-op when it is given more than one root element.
      assert_nil doc.at_css("template[x-if]"),
                 "the signal must not use template x-if"
      assert root.key?("x-show"), "the #{name} variant must be mounted and hidden, not absent"

      # The tone dot, and a label or an address to read beside it. A chip that
      # is only a colour is a puzzle.
      refute_nil doc.at_css("[data-wallet-signal-dot]"), "the #{name} variant has no tone dot"
      assert doc.at_css("[data-wallet-signal-label]") || doc.at_css("[data-wallet-signal-address]"),
             "the #{name} variant renders a colour and no words"
    end

    test "every Alpine expression in the #{name} variant survives ERB whole" do
      doc = render_signal(locals)
      attributes = alpine_attributes(doc)

      refute_empty attributes, "found no Alpine attributes to check — this guard would be vacuous"

      # GREPPING FOR THE QUOTE CANNOT WORK, and believing it does is the trap.
      # A parser ENDS the attribute at the stray quote, so the value handed back
      # is short and perfectly clean; the quote is not in it to find. Chrome does
      # the same thing, which is why a dead component renders flawless markup.
      #
      # What a truncation always leaves is a SEVERED EXPRESSION: a dangling
      # operator, or brackets and string quotes that no longer balance. That is
      # what is asserted, on every Alpine attribute, named or not.
      attributes.each do |attr|
        value = attr.value
        where = "#{attr.name} on <#{attr.parent.name}>"

        refute_includes value, '"', "#{where} carries a double quote"

        assert_equal value.count("("), value.count(")"), "#{where} has unbalanced parentheses: #{value.inspect}"
        assert_equal value.count("{"), value.count("}"), "#{where} has unbalanced braces: #{value.inspect}"
        assert_equal 0, value.count("'") % 2, "#{where} has an unclosed string: #{value.inspect}"
        refute_match(/(===|!==|&&|\|\||[+?:,.])\s*\z/, value,
                     "#{where} ends mid-expression, which is what a stray double quote leaves behind: #{value.inspect}")
      end

      # And the tail of the longest one by name, because a truncation late in a
      # long map can still balance by luck.
      tone_map = attributes.find { |a| a.value.include?("tone === ") }
      refute_nil tone_map, "the tone class map is gone; the dot can no longer take a colour"
      assert_includes tone_map.value, "muted",
                      "the tone map is truncated — its last arm did not survive ERB"
    end
  end

  test "the panel names the declared and the undeclared switch in different words" do
    doc = render_signal(variant: :panel)

    expected_note = doc.at_css("[data-wallet-signal-expected-note]")
    changed_note = doc.at_css("[data-wallet-signal-changed-note]")

    refute_nil expected_note, "a declared ceremony switch has nothing to say on the page"
    refute_nil changed_note, "an undeclared switch has nothing to say on the page"

    assert_includes expected_note["x-show"], "expected"
    assert_includes changed_note["x-show"], "changed"

    # They are DIFFERENT sentences. A signal that says the same thing either way
    # has removed the distinction rather than shown it, which is the one thing
    # this change was told not to do.
    refute_equal expected_note.text.squish, changed_note.text.squish

    # And the reassuring one must not read as an alarm.
    refute_match(/not one the page asked for/, expected_note.text)
  end

  test "danger text sits on a theme surface rather than a red tint" do
    doc = render_signal(variant: :panel)
    root = doc.at_css("[data-wallet-signal]")

    # text-danger-ink is derived to clear AA against the four THEME surfaces.
    # Composited over a red wash it measures 4.25:1 and fails, so the affordance
    # is a red BORDER over bg-surface-alt. docs/UI_PATTERNS.md carries the
    # measurements; test/views/error_text_contrast_test.rb carries the guard.
    assert_includes root["class"], "bg-surface-alt"
    refute_match(/bg-red-\d+\/\d+/, root["class"].to_s,
                 "a red tint under danger ink drops it below AA")

    changed_note = doc.at_css("[data-wallet-signal-changed-note]")
    assert_includes changed_note["class"], "text-danger-ink",
                    "a static red fails AA on this app's light theme"
    refute_match(/text-red-\d+/, changed_note["class"].to_s)
  end

  test "the panel takes a caller-supplied heading" do
    doc = render_signal(variant: :panel, label: "Co-signing wallet")
    assert_includes doc.text, "Co-signing wallet"
  end
end
