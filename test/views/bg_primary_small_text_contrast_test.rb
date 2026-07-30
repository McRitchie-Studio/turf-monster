require "test_helper"

# Component tier for the small-text-on-bg-primary accessibility guard
# (task: sweep-bg-primary-contrast).
#
# The theme primary (#4baf50) paints white text at only 2.78:1 — below WCAG AA
# (4.5:1 for small text) in BOTH themes. PR 249 fixed ONE instance (the
# pack-button savings pill); a Carl sweep then found ~10 more small-text
# bg-primary/text-white fills still at 2.78:1 (six text-xs, four text-sm). The
# durable fix lives in app/assets/tailwind/application.css: an unlayered,
# compound-selector override that darkens the FILL to an AA-passing green
# whenever bg-primary carries small white text, so a future
# `bg-primary text-white text-xs` fill inherits AA for free.
#
# This test asserts the PROPERTY (a computed contrast ratio), not a spelling.
# Re-introducing any sub-4.5:1 fill for the small-text-primary combination —
# including via a LATER same-specificity override rule (e.g. a dark-mode
# `html.dark .bg-primary.text-xs { ... }`) — turns it red. The last-wins
# extraction below is the carry-over from PR 249's known gap, whose
# declared_colors matched only the FIRST rule and let a later override escape.
class BgPrimarySmallTextContrastTest < ActiveSupport::TestCase
  APP_CSS = Rails.root.join("app/assets/tailwind/application.css").freeze

  # WCAG 2.1 relative luminance / contrast ratio.
  def contrast(hex_a, hex_b)
    rel = lambda do |hex|
      r, g, b = hex.delete("#").scan(/../).map { |c| c.to_i(16) / 255.0 }
      lin = ->(v) { v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055)**2.4 }
      0.2126 * lin[r] + 0.7152 * lin[g] + 0.0722 * lin[b]
    end
    a, b = rel[hex_a], rel[hex_b]
    (([a, b].max + 0.05) / ([a, b].min + 0.05))
  end

  # Every LEAF rule (selector, declarations) in source order. `[^{}]+` bodies
  # skip the @media/@keyframes wrappers but still capture the rules nested
  # INSIDE them with their own selector — so a dark-mode override buried in an
  # @media block is seen exactly like a top-level one.
  def leaf_rules(css)
    css.scan(/([^{}]+)\{([^{}]+)\}/m).map { |sel, body| [sel.strip, body] }
  end

  # A selector styling small (text-xs / text-sm) text on the primary fill.
  def small_primary_selector?(selector)
    selector.include?(".bg-primary") &&
      (selector.include?(".text-xs") || selector.include?(".text-sm"))
  end

  def background_hex(body)
    body[/background(?:-color)?:\s*(#[0-9a-fA-F]{3,6})/, 1]
  end

  # LAST-WINS: the effective fill the browser paints is the last matching
  # rule's background, not the first. This is the whole point of the carry-over.
  def effective_small_primary_fill(css)
    leaf_rules(css)
      .select { |sel, body| small_primary_selector?(sel) && background_hex(body) }
      .map    { |_sel, body| background_hex(body) }
      .last
  end

  # The theme primary resolved exactly as production resolves it, so the "why"
  # is measured, not asserted from a memorised hex.
  def resolved_primary
    Studio::ThemeResolver.new(Studio.theme_config).primary_palette_vars["--color-primary"]
  end

  # ── the guarded bug, measured ─────────────────────────────────────────────

  test "white on the theme primary fails AA for small text (the bug this guards)" do
    ratio = contrast("#ffffff", resolved_primary)
    assert_operator ratio, :<, 4.5,
                    "if the primary ever clears 4.5:1 the override is unnecessary; " \
                    "today it is #{format('%.2f', ratio)}:1 (#{resolved_primary}) — the failure."
  end

  # ── the fix, measured as a property ───────────────────────────────────────

  test "the small-text bg-primary override paints an AA-passing fill against white" do
    css  = APP_CSS.read
    fill = effective_small_primary_fill(css)
    refute_nil fill,
               "no rule in application.css darkens small white text on bg-primary — the " \
               "AA guard is missing. Expected e.g. `.bg-primary.text-white.text-xs { background-color: #1b5e20 }`."

    ratio = contrast("#ffffff", fill)
    assert_operator ratio, :>=, 4.5,
                    "small-text bg-primary fill is #{format('%.2f', ratio)}:1 (white on #{fill}) — " \
                    "AA needs 4.5:1. The theme primary #4baf50 is 2.78:1, which is the bug this guards."
  end

  # ── last-wins: a later same-specificity override must be the one evaluated ──
  #
  # PR 249's declared_colors matched only the FIRST rule, so Carl could append a
  # second same-specificity rule (a dark-mode override is exactly this shape)
  # that repainted 2.78:1 while the suite stayed green. This proves the
  # extraction now takes the LAST rule, so that override would be caught.

  test "extraction is last-wins, so a later override reintroducing the bug is caught" do
    css = <<~CSS
      .bg-primary.text-white.text-xs { background-color: #1b5e20; } /* passes at 7.87:1 */
      html.dark .bg-primary.text-white.text-xs { background-color: #4baf50; } /* later override reintroduces 2.78:1 */
    CSS

    fill = effective_small_primary_fill(css)
    assert_equal "#4baf50", fill.downcase,
                 "the extractor must evaluate the LAST matching rule, not the first"
    assert_operator contrast("#ffffff", fill), :<, 4.5,
                    "and because it does, the real guard above would go red on such an override"
  end

  # A first-match extractor would have missed it — pin that contrast so the
  # last-wins behaviour can't silently regress to first-match.
  test "a first-match reading of the same override would have missed the regression" do
    css = <<~CSS
      .bg-primary.text-white.text-xs { background-color: #1b5e20; }
      html.dark .bg-primary.text-white.text-xs { background-color: #4baf50; }
    CSS
    first = leaf_rules(css)
             .select { |sel, body| small_primary_selector?(sel) && background_hex(body) }
             .map    { |_sel, body| background_hex(body) }
             .first
    assert_equal "#1b5e20", first.downcase
    assert_operator contrast("#ffffff", first), :>=, 4.5,
                    "the FIRST rule passes — which is exactly why first-match was blind to the override"
  end
end
