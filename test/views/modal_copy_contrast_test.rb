require "test_helper"

# Component tier for modal body-copy contrast (task: raise-modal-copy-contrast,
# folded into sweep-bg-primary-contrast).
#
# Modal lead-in copy sat at `text-secondary`, which measured 4.35:1 on the
# modal surface in DARK under engine < 0.31 — below WCAG AA (4.5:1). It passes
# in light (4.76:1), so this was a dark-mode-only failure that reasoning-by-eye
# missed. The sweep moved the surface lead-in paragraphs to `text-body`
# (9.05:1 dark / 10.35:1 light — AA and AAA). Copy that already sits on the
# darker sub-surfaces (bg-inset, bg-surface-alt) stays text-secondary: it
# measures 7+:1 there and passes.
#
# Engine 0.31 changed the ground truth: text-secondary now DERIVES from the
# theme base by a bounded contrast search and clears AA (~5.74:1 here), so the
# characterization below is version-aware — it asserts the sub-AA bug only on
# pre-0.31 engines and the fixed property from 0.31 on. (The sweep to
# text-body stays correct either way — belt on top of the engine's fix.)
#
# Tokens are resolved exactly as production resolves them (Studio::ThemeResolver
# over Studio.theme_config), so both claims are MEASURED, not asserted from a
# memorised ratio.
class ModalCopyContrastTest < ActiveSupport::TestCase
  MODALS_DIR = Rails.root.join("app/views/modals").freeze

  def contrast(hex_a, hex_b)
    rel = lambda do |hex|
      r, g, b = hex.delete("#").scan(/../).map { |c| c.to_i(16) / 255.0 }
      lin = ->(v) { v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055)**2.4 }
      0.2126 * lin[r] + 0.7152 * lin[g] + 0.0722 * lin[b]
    end
    a, b = rel[hex_a], rel[hex_b]
    (([a, b].max + 0.05) / ([a, b].min + 0.05))
  end

  def theme
    resolver = Studio::ThemeResolver.new(Studio.theme_config)
    { dark: resolver.dark_mode_vars, light: resolver.light_mode_vars }
  end

  # ── the token we swept TO clears AA on the modal surface, both themes ──────

  test "text-body clears AA on the modal surface in both themes" do
    %i[dark light].each do |mode|
      vars  = theme[mode]
      ratio = contrast(vars["--color-text-body"], vars["--color-surface"])
      assert_operator ratio, :>=, 4.5,
                      "text-body is #{format('%.2f', ratio)}:1 on bg-surface in #{mode} — must clear AA (4.5:1)"
    end
  end

  # ── the token we swept AWAY from, measured as the reason ──────────────────

  test "text-secondary contrast on the modal surface matches the engine era" do
    vars  = theme[:dark]
    ratio = contrast(vars["--color-text-secondary"], vars["--color-surface"])
    if Gem::Version.new(Studio::VERSION) >= Gem::Version.new("0.31.0")
      assert_operator ratio, :>=, 4.5,
                      "text-secondary is #{format('%.2f', ratio)}:1 on bg-surface (dark) — engine >= 0.31 " \
                      "derives it to clear AA; below 4.5:1 the engine regressed"
    else
      assert_operator ratio, :<, 4.5,
                      "text-secondary is #{format('%.2f', ratio)}:1 on bg-surface (dark) — the sub-AA " \
                      "value the sweep replaced (pre-0.31 characterization)"
    end
  end

  # ── regression invariant: centered modal copy never uses text-secondary ────
  #
  # Centered <p> copy is the lead-in text that sits on the modal SURFACE, where
  # text-secondary fails AA in dark. text-body passes on every modal background
  # (surface 9.05:1, the darker sub-surfaces higher still), so the safe rule is:
  # centered modal paragraph copy uses text-body, never text-secondary. The scan
  # is multiline-aware so a <p> whose class list wraps across lines can't slip
  # through.

  def offending_centered_paragraphs
    Dir.glob(MODALS_DIR.join("**/*.html.erb")).each_with_object([]) do |abs, found|
      rel  = Pathname.new(abs).relative_path_from(Rails.root).to_s
      html = File.read(abs)
      html.scan(/<p\b([^>]*?)>/m) do |attrs,|
        a = attrs.first if attrs.is_a?(Array)
        a ||= attrs
        found << rel if a.include?("text-center") && a.include?("text-secondary")
      end
    end
  end

  test "no centered modal paragraph uses text-secondary" do
    offenders = offending_centered_paragraphs
    assert_empty offenders,
                 "centered modal copy sits on bg-surface, where text-secondary is 4.35:1 in dark " \
                 "(below AA). Use text-body (9.05:1). Offending file(s): #{offenders.uniq.inspect}"
  end

  # Anchor the specific flagged instance so the fix can't be reverted silently.
  test "the flagged token-picker lead-in renders with text-body" do
    html = MODALS_DIR.join("auth/_tokens.html.erb").read
    lead = html[/<p[^>]*>1 token = 1 contest entry[^<]*/m]
    refute_nil lead, "could not find the token-picker lead-in paragraph"
    assert_includes lead, "text-body", "the lead-in must use the AA-passing text-body token"
    refute_includes lead, "text-secondary", "the lead-in must no longer use the sub-AA text-secondary token"
  end
end
