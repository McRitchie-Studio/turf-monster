# frozen_string_literal: true

require "test_helper"
require "nokogiri"

# [integration] This app's FORK of the modal host must carry the engine's focus
# contract.
#
# WHY A TEST HERE AT ALL, when the engine already has one. studio-engine is
# NON-ISOLATED, so an app view SHADOWS the engine view of the same path. This app
# ships its own app/views/studio/modals/_host.html.erb, so the
# engine's file is NEVER RENDERED in this app — and a gem bump therefore does not
# deliver a single one of these fixes. Verified before porting: the fork carried
# no captureFocus, no tabindex=-1, no tab trap, no cycleFocus and no dialogLabel.
# Only _scoped_host, which is unforked, propagates from the engine.
#
# So the engine's coverage says nothing about what this app's users get. This
# does.
class ModalHostFocusContractTest < ActionDispatch::IntegrationTest
  HOST = "app/views/studio/modals/_host.html.erb"

  def host_source = File.read(Rails.root.join(HOST))

  # THE BACKDROP ELEMENT, parsed out of the RENDERED page.
  #
  # WHY NOT assert_includes ON THE SOURCE — this is the trap the first version of
  # this file fell into, caught by mutation in review. `assert_includes src,
  # "captureFocus"` is a bare substring, and this host DOCUMENTS captureFocus in its
  # own JS comments. Deleting the x-init BINDING left it green. So did deleting the
  # whole captureFocus function. And because those are `//` comments inside <script>,
  # they are emitted into the rendered HTML too — which defeated the "RENDERED, not
  # just source" test written to guard exactly this trap.
  #
  # An attribute on a parsed ELEMENT cannot be satisfied by prose. That is the whole
  # reason for the parser.
  #
  # NOKOGIRI::HTML5, NOT NOKOGIRI::HTML. libxml2 silently DROPS every Alpine event
  # attribute. Measured on this page: the libxml2 parse of this backdrop returns 9
  # attributes, the HTML5 parse returns 11, and the two it loses are
  # @keydown.tab.prevent (the entire tab trap) and @click.self (click-outside
  # dismissal) — it also mangles @keydown.escape.window into a bare `false`
  # attribute. A test on Nokogiri::HTML would report the trap missing, and the
  # tempting next move is to stop asserting it.
  def backdrop
    get root_path
    follow_redirect! while response.redirect?
    assert_response :success

    node = Nokogiri::HTML5(response.body).at_css('[role="dialog"]')
    assert node, "the rendered page carries no [role=\"dialog\"] backdrop at all — the host " \
                 "partial is not reaching this page, so nothing below proves anything"
    node
  end

  test "the rendered backdrop element carries the whole focus contract" do
    el = backdrop

    assert_equal "-1", el["tabindex"],
                 "the backdrop is not focusable, so captureFocus has nowhere to land that is not " \
                 "a button (a stray Enter would fire it)"
    assert_equal "true", el["aria-modal"], "the dialog does not announce as modal"
    assert_match(/captureFocus\(\$el\)/, el["x-init"].to_s,
                 "the backdrop has no x-init calling captureFocus — the dialog opens with focus " \
                 "still on the page behind it. This is the ORIGINAL measured defect, and the " \
                 "substring version of this assertion could not see it")
    assert_match(/cycleFocus\(\$el, \$event\)/, el["@keydown.tab.prevent"].to_s,
                 "Tab is not intercepted and re-dispatched inside the dialog; native tabbing " \
                 "walks straight out")
    assert_match(/dialogLabel\(\)/, el[":aria-label"].to_s,
                 "the name is computed but never bound to the element — the dialog announces as " \
                 "just \"dialog\"")
  end

  # EVERY FUNCTION THE BACKDROP BINDS MUST EXIST.
  #
  # The element test above proves the WIRING is present; it cannot prove there is
  # anything on the other end of it. Found by mutation: deleting the entire
  # captureFocus FUNCTION leaves every attribute assertion green, because the x-init
  # attribute still reads "$store.modals.captureFocus($el)" — it just points at
  # nothing, and Alpine throws at runtime where no Rails test is looking.
  #
  # The function names are READ OUT of the rendered attributes rather than listed
  # here, so a renamed binding drags its definition along and a new binding is
  # covered the day it is added. Anchored on the DEFINITION form (`name: function(`),
  # which prose cannot satisfy — the whole reason the substring version failed.
  test "every store function the backdrop binds is actually defined" do
    el = backdrop
    src = host_source

    called = %w[x-init @keydown.tab.prevent :aria-label @keydown.escape.window @click.self]
             .flat_map { |a| el[a].to_s.scan(/\$store\.modals\.(\w+)\(/) }
             .flatten.uniq.sort

    assert_operator called.length, :>=, 4,
                    "expected the backdrop to bind at least capture/cycle/label/close, got " \
                    "#{called.inspect} — if the bindings moved, re-point this test"

    called.each do |name|
      assert_match(/\b#{Regexp.escape(name)}: function\s*\(/, src,
                   "the backdrop binds $store.modals.#{name}(), and the store never DEFINES it. " \
                   "The attribute assertions above stay green on this — they prove the wire, not " \
                   "what is on the end of it — and Alpine throws in the browser where no Rails " \
                   "test is looking.")
    end
  end

  # THE FOURTH ENGINE FIX, which this fork missed entirely. The backdrop centres the
  # card with `flex items-center`, so a card taller than the viewport is clipped past
  # BOTH edges with nothing scrollable and its actions unreachable — and on a
  # dismissible: false card escape and click-outside are gated off, so there is no way
  # out at all. It arrived in the engine in the SAME commit as captureFocus.
  test "the rendered card can scroll instead of clipping its own actions away" do
    card = backdrop.at_css("div")

    assert card, "the backdrop renders no card element"
    classes = card["class"].to_s
    assert_includes classes, "max-h-[85dvh]",
                    "the card has no height cap, so a tall card runs past both edges of the " \
                    "viewport (dvh, not vh, so mobile browser chrome counts)"
    assert_includes classes, "overflow-y-auto",
                    "the card is capped but cannot scroll, which is strictly worse: the content " \
                    "below the cap is unreachable rather than merely off-screen"
  end

  # THE SWAP DEFECT, which is the one the engine's review sent back. A swap keeps
  # current() truthy, so the outer template never re-mounts and x-init never
  # re-runs — the trap would hold on open and release on every swap.
  test "the forked host re-focuses after a swap" do
    src = host_source

    assert_includes src, "refocus: function",
                    "the fork has no refocus() — the trap releases on the first swap"
    # Anchored on the RECEIVER, not the bare name: this file documents refocus()
    # in prose, so a bare /refocus\(\)/ matches the comment and stays green with
    # every call deleted. That exact trap was caught by mutation in the engine.
    assert_match(/self\.refocus\(\)/, src,
                 "refocus() is defined but never CALLED, which is the same as not having it")
  end

  # FOCUS MUST COME BACK. Without releaseFocus the opener never regains focus and
  # a keyboard user is stranded on a detached backdrop.
  test "the forked host returns focus to the opener when the last dialog closes" do
    src = host_source

    assert_includes src, "releaseFocus",
                    "the fork never restores focus, so closing strands the keyboard user"
    assert_match(/self\.releaseFocus\(\)|this\.releaseFocus\(\)/, src,
                 "releaseFocus is defined but never called")
  end

  # THE ACCESSIBLE NAME. An unnamed dialog announces as just "dialog".
  test "the forked host names the dialog" do
    src = host_source

    assert_includes src, "dialogLabel",
                    "the dialog has no accessible name — it announces as just 'dialog'"
    assert_match(/:aria-label=/, src, "the name is computed but never bound to the element")
  end

  # CLOSE() MUST RELEASE EVEN WHEN THE ENTRY IS ALREADY GONE.
  #
  # This fork put `if (!self.stack.length) self.releaseFocus();` INSIDE the
  # `if (idx >= 0)` block; the engine puts it outside (_host.html.erb:494). Trigger:
  # press Escape on a dismissible modal, then let clearStaleModals() ->
  # closeAllDismissible() fire from turbo:before-cache or a bfcache pageshow inside
  # the 220ms exit window. The entry is already spliced, idx is -1, the block is
  # skipped, releaseFocus never runs — focus is stranded on a detached backdrop and
  # _returnFocusTo / _backdropEl leak into the next dialog.
  #
  # Asserted on BRACE DEPTH rather than on a substring, because both placements
  # contain the identical call text and only their nesting differs. Depth is counted
  # from the setTimeout callback, so the release must sit at depth 1 (the callback's
  # own body) and not at depth 2 (inside the idx guard).
  test "close() releases focus outside the already-spliced guard" do
    src = host_source
    body = src[/close: function\(\).*?\n        \},/m]

    refute_nil body, "close() moved — re-point this test rather than deleting it"

    call_at = body.index(/self\.releaseFocus\(\)/)
    guard_at = body.index("var idx = self.stack.indexOf(entry);")

    assert call_at && guard_at, "close() no longer both guards on idx and releases focus"

    depth = body[guard_at...call_at].count("{") - body[guard_at...call_at].count("}")

    assert_equal 0, depth,
                 "self.releaseFocus() sits #{depth} brace level(s) inside the `if (idx >= 0)` " \
                 "guard, so it is skipped whenever the entry was ALREADY removed — the exact " \
                 "Escape-then-bfcache window that strands focus on a detached backdrop. The " \
                 "stack length is the condition; whether THIS call did the splicing is not."
  end
end
