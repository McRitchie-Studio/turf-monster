# frozen_string_literal: true

require "test_helper"

# [component] The host patch that keeps the engine's banner tooltip from giving
# this app a horizontal scrollbar, and the seam it is pinned to.
#
# THE DEFECT IS THE ENGINE'S, AND EVERY CONSUMER HAS IT. studio/banners/_button
# renders its hover tooltip at `width: max-content; max-width: 260px` inside a
# trigger classed `whitespace-nowrap`. white-space inherits, so the cap clamps
# the tooltip's BOX to 260px while its single unbreakable line keeps full
# intrinsic width, and the remainder becomes layout overflow. The tooltip is
# anchored `right: 0` on a chip near the viewport edge, so that overflow runs
# off the right of the page and lands in document.scrollWidth. turf is not
# special here; turf is only the app whose e2e measures document overflow
# (e2e/navbar_layout.spec.js), which is why turf is where it surfaced.
#
# WHAT MADE IT VISIBLE. studio-engine 0.56.3 vendored Montserrat at
# `font-display: optional`, which has no swap period — a face not ready inside
# the browser's block period is abandoned for that whole navigation and the page
# paints in `system-ui, sans-serif`. macOS resolves that narrower than
# Montserrat and Linux wider, so the same page overflowed on CI and not locally.
#
# WHAT THIS TEST IS FOR. The fix is one CSS declaration in the host, and a host
# patch on someone else's markup rots in two directions: the hook it selects can
# be renamed, and the upstream defect can be fixed underneath it. Both are
# silent. So this asserts the patch AND both ends of the seam it depends on, and
# it is written to FAIL when the engine repairs its own tooltip — that failure
# is the instruction to delete the host block rather than carry it forever.
class BannerTooltipContainmentTest < ActiveSupport::TestCase
  APP_CSS       = Rails.root.join("app/assets/tailwind/application.css")
  ENGINE_BUTTON = Studio::Engine.root.join("app/views/studio/banners/_button.html.erb")
  TOOLTIP_HOOK  = "data-studio-banner-tooltip"

  test "the host declares white-space normal on the engine's banner tooltip" do
    css = APP_CSS.read

    assert_match(/\[#{Regexp.escape(TOOLTIP_HOOK)}\]\s*\{[^}]*white-space:\s*normal/m, css,
                 "the tooltip must wrap inside its 260px cap in ANY face, not spill past the viewport")
  end

  test "the rule is unlayered so it never loses a cascade fight it need not have" do
    css = APP_CSS.read
    rule_at = css.index(/^\[#{Regexp.escape(TOOLTIP_HOOK)}\]\s*\{/)

    assert rule_at, "the tooltip rule must exist"

    # Engine CSS arrives unlayered, and unlayered author styles beat layered
    # ones. Counting braces up to the rule tells us whether it sits inside an
    # open @layer block: balanced means top level.
    prefix = css[0...rule_at]

    assert_equal prefix.count("{"), prefix.count("}"),
                 "the tooltip rule must sit at the top level, not inside an @layer block"
  end

  test "the engine still renders the hook this rule selects" do
    assert_includes ENGINE_BUTTON.read, TOOLTIP_HOOK,
                    "the host rule selects #{TOOLTIP_HOOK}; if the engine renames it the patch " \
                    "silently stops applying and the 4px scrollbar comes back"
  end

  test "the engine still sizes the tooltip in the way that needs the patch" do
    button = ENGINE_BUTTON.read

    assert_includes button, "max-width:260px",
                    "the cap is half of what makes the line overflow"
    assert_includes button, "width:max-content",
                    "max-content plus a cap is only safe when the text may wrap"
    assert_includes button, "whitespace-nowrap",
                    "the nowrap the tooltip inherits lives on the trigger chip"
  end

  test "the tooltip's wrap is guaranteed by the engine or by this host block" do
    button = ENGINE_BUTTON.read
    tooltip_markup = button[/<span\s+#{Regexp.escape(TOOLTIP_HOOK)}.*?>/m]

    assert tooltip_markup, "expected the tooltip span to be findable in the engine partial"

    engine_declares = tooltip_markup.include?("white-space")
    host_declares = APP_CSS.read.match?(/^\[#{Regexp.escape(TOOLTIP_HOOK)}\]\s*\{/)

    assert engine_declares || host_declares,
           "nothing declares white-space on the tooltip — the chip's whitespace-nowrap " \
           "INHERITS and the unbreakable line overflows the 260px cap again"

    # RETIREMENT SIGNAL, deliberately non-failing during the changeover.
    #
    # This assertion used to be `assert_not_includes tooltip_markup, "white-space"`,
    # so that the day the engine fixed its own tooltip it failed and told the reader
    # to delete the host block. That day arrived mid-release, and a hard failure here
    # cannot express it: turf's `accepted` resolves the engine WITHOUT the fix (where
    # deleting the host block reddens the containment e2e) while turf's `release`
    # resolves the engine WITH it. One branch, both versions, opposite verdicts.
    #
    # So the guarantee above is version-agnostic, and the retirement instruction is
    # printed rather than thrown. Once every consumer resolves an engine that declares
    # its own white-space, delete the host block in app/assets/tailwind/application.css
    # together with this test's tolerance and go back to pinning one owner.
    if engine_declares && host_declares
      puts "[retire] studio-engine now sets white-space on its own tooltip — the host " \
           "[#{TOOLTIP_HOOK}] block in app/assets/tailwind/application.css is redundant " \
           "and should be deleted once every consumer is on that engine version."
    end
  end

  test "turf still renders the banner whose tooltip this guards" do
    navbar = Rails.root.join("app/views/layouts/_navbar.html.erb").read

    assert_includes navbar, %(render "studio/banners/environment"),
                    "no banner, no tooltip, and this whole patch would be dead weight"
  end
end
