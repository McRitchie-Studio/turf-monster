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

  # SCOPED TO THE VARIANT JUST RENDERED, and that is not tidiness.
  # ActionView::TestCase's `rendered` is an ACCUMULATING buffer: a test that
  # renders the panel and then the chip parses a fragment holding both, and
  # `at_css("[data-wallet-signal]")` hands back the PANEL either time. Measured
  # here — an assertion that the chip does not claim to be a ceremony surface
  # failed against the panel's markup while the chip was correct.
  def render_signal(locals = {})
    variant = locals.fetch(:variant, :chip).to_s
    render partial: "shared/wallet_signal", locals: locals
    node = Nokogiri::HTML::DocumentFragment
           .parse(rendered)
           .css("[data-wallet-signal-variant=#{variant}]")
           .last
    refute_nil node, "the #{variant} variant rendered no signal at all"
    Nokogiri::HTML::DocumentFragment.parse(node.to_html)
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

    # And the reassuring one must not read as an alarm. The phrase is quoted from
    # the LIVE alarm sentence: a refute_match on wording no note carries any more
    # passes while proving nothing, so it moves when the copy does.
    refute_match(/not one the page is currently asking for/, expected_note.text)
  end

  # ── The post-ceremony sentence, and the false alarm it replaced ──────────
  #
  # cosign.js clears $store.wallet.expectedSwitchAddresses in its `finally`, the
  # instant the last signature is collected and while Phantom is still on the
  # signer it just used. The panel used to re-derive `changed` there — red border,
  # danger ink, and a sentence denying that any ceremony had asked for this wallet
  # — with no wallet event behind it and the hand-off card correctly still down.
  test "a finished ceremony gets its own sentence instead of the alarm" do
    doc = render_signal(variant: :panel)

    ended = doc.at_css("[data-wallet-signal-ended-note]")
    expected_note = doc.at_css("[data-wallet-signal-expected-note]")
    changed_note = doc.at_css("[data-wallet-signal-changed-note]")

    refute_nil ended,
               "a completed ceremony leaves the operator parked on a vault signer and " \
               "the panel has nothing to say about it"

    # Gated on opposite sides of one fact, so the mid-ceremony sentence and the
    # finished one can never both render.
    assert_includes ended["x-show"], "declarationEnded"
    assert_includes expected_note["x-show"], "!$store.walletSignal.declarationEnded"

    # It is CALM. The alarm's affordances are danger ink and the red border, and
    # this sentence carries neither — that is the whole defect it closes.
    refute_includes ended["class"].to_s, "text-danger-ink"
    assert_includes changed_note["class"].to_s, "text-danger-ink",
                    "the real alarm must keep its ink, or this guard proves nothing"

    # And it says a ceremony HAPPENED, which is the clause the old rendering denied.
    assert_match(/ceremony that asked for this wallet/, ended.text.squish)
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

  # ── The rework: what an email-authenticated admin is shown ──────────────

  test "the panel declares the page a ceremony surface and the chip does not" do
    chip = render_signal.at_css("[data-wallet-signal]")
    panel = render_signal(variant: :panel).at_css("[data-wallet-signal]")

    # wallet_signal.js reads this off the DOM to decide whether the BROWSER
    # wallet is what signs here. It is what lets an admin who signed in by
    # magic link see a declared wallet differently from a stranger's; without
    # it they read the same grey "Managed wallet" for both.
    assert panel.key?("data-wallet-signal-ceremony"),
           "the panel must mark its page as one where the browser wallet signs"
    refute chip.key?("data-wallet-signal-ceremony"),
           "the chip renders on every page and must not make that claim for all of them"
  end

  test "the panel hides on a quiet-listed STATE, not on the chip's quiet field" do
    panel = render_signal(variant: :panel).at_css("[data-wallet-signal]")
    chip = render_signal.at_css("[data-wallet-signal]")

    # A signed-in user with no wallet on their account derives `guest`, whose
    # label is "Not signed in" — a sentence that must never reach an
    # authenticated admin. The derivation keeps that state off a ceremony page,
    # and this is the second lock: if the ceremony flag ever fails to read, the
    # panel degrades to hidden rather than to a confident grey dot over two
    # different addresses.
    #
    # ASSERTING "quiet" HERE WAS NOT ENOUGH, and that is why this test moved.
    # `quiet` is `<quiet state> && !address`, so it is false whenever a wallet IS
    # connected — and a connected wallet is the only way two different addresses
    # reach the screen. The old assertion passed on the substring while the
    # property it described could not fire. The panel gates on the state alone;
    # the chip keeps `quiet`, which is correct for its own question. The property
    # itself is measured under node in test/lib/wallet_signal_js_test.rb.
    assert_includes panel["x-show"], "quietState",
                    "the panel's lock must read the STATE, not the chip's quiet field"
    assert_includes chip["x-show"], "quiet"
    refute_includes chip["x-show"], "quietState",
                    "the chip's question is 'anything worth painting', and an address always is"
  end

  test "the undeclared note speaks differently to a session that proved no wallet" do
    doc = render_signal(variant: :panel)

    proved = doc.at_css("[data-wallet-signal-changed-note]")
    unproved = doc.at_css("[data-wallet-signal-changed-note-unproved]")

    refute_nil proved, "the wallet-authenticated reader lost their sentence"
    refute_nil unproved,
               "an admin who signed in by email gets no wallet-changed card at all — " \
               "solana_stores.js returns early unless the session is web3 — so the words " \
               "on the page are the whole of what they get"

    # Gated on opposite sides of the same fact, so exactly one can render.
    assert_includes proved["x-show"], "walletAuthenticated"
    assert_includes unproved["x-show"], "!$store.walletSignal.walletAuthenticated"

    # The old single sentence told an email admin this was not "the wallet this
    # session signed in with", which they never did with any wallet. Different
    # sentences, and the unproved one must not repeat that exact claim — it says
    # the opposite ("this session never signed in with one"), so the guard has to
    # name the claim rather than the words it shares with its own correction.
    refute_equal proved.text.squish, unproved.text.squish
    assert_match(/the wallet this session signed in with/, proved.text.squish)
    refute_match(/the wallet this session signed in with/, unproved.text.squish)
  end

  test "the session row disclaims itself when the session proved no wallet" do
    doc = render_signal(variant: :panel)

    label = doc.at_css("[data-wallet-signal-session-label]")
    note = doc.at_css("[data-wallet-signal-session-note]")

    refute_nil label, "the session row label must follow whether the session proved a wallet"
    assert_includes label["x-text"], "walletAuthenticated"
    assert_includes label["x-text"], "Account wallet"
    assert_includes label["x-text"], "Session wallet"

    refute_nil note, "an unproved session address beside a different connected one reads as a checked pair"
    assert_includes note["x-show"], "!$store.walletSignal.walletAuthenticated"
    assert_match(/without a wallet/, note.text)
  end

  test "the panel takes a caller-supplied heading" do
    doc = render_signal(variant: :panel, label: "Co-signing wallet")
    assert_includes doc.text, "Co-signing wallet"
  end
end
