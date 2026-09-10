require "test_helper"

# Guards turf-monster's studio-engine component-CSS adoption
# (task: turf-adopt-engine-css).
#
# The change this locks in: TM sources its .btn* / .card-hover / .badge /
# .input-field / .empty-state / .json-debug / .label-upper utilities from the
# studio-engine build import instead of local forks. TM's ONE divergence — a
# violet secondary button and a lighten-in-place neutral button — is expressed
# through the engine's --btn-* custom-property token contract (studio-engine
# 0.15+), NOT by re-declaring the @utility (a local @utility redeclaration is
# ADDITIVE in Tailwind v4 — both definitions emit and the engine's rules leak
# in, so a fork is never a clean override).
#
# The regression risk is STRUCTURAL: a future edit silently re-forking a shared
# class (which then drifts from the engine, and — for btn-secondary/btn-neutral
# — double-emits with the engine's rules), dropping the import (which strips the
# components), or dropping the :root tokens (which reverts the violet secondary
# to the engine's green default). This guards every end of that seam.
class ComponentCssProvenanceTest < ActiveSupport::TestCase
  APP_CSS    = Rails.root.join("app/assets/tailwind/application.css")
  ENGINE_CSS = Studio::Engine.root.join("app/assets/tailwind/studio_engine/engine.css")

  # Utilities TM delegates WHOLESALE to the engine — it must not re-declare any
  # of these. `card` is intentionally excluded: TM keeps a nested-only @utility
  # card for its .lp-splash / .seeds-invite-row context (the BASE still comes
  # from the engine), asserted separately below.
  DELEGATED_UTILITIES = %w[
    btn btn-primary btn-secondary btn-outline btn-danger btn-warning btn-success
    btn-google btn-neutral btn-sm btn-lg
    card-hover badge input-field empty-state json-debug label-upper
  ].freeze

  # Balanced-brace extractor for a single `@utility <name> { ... }` block
  # (the shallow `[^{}]` trick fails on card's nested context selectors).
  def utility_block(css, name)
    m = css.match(/@utility\s+#{Regexp.escape(name)}\s*\{/)
    return nil unless m
    open = css.index("{", m.begin(0))
    depth = 0
    open.upto(css.length - 1) do |j|
      depth += 1 if css[j] == "{"
      depth -= 1 if css[j] == "}"
      return css[(open + 1)...j] if depth.zero?
    end
    nil
  end

  test "[component] application.css imports the studio-engine component build" do
    assert_match %r{@import\s+['"]\.\./builds/tailwind/studio_engine['"]}, APP_CSS.read,
      "application.css must @import ../builds/tailwind/studio_engine so the shared " \
      "component utilities come from studio-engine, not a local fork"
  end

  test "[component] application.css does not re-fork the delegated engine utilities" do
    css = APP_CSS.read
    DELEGATED_UTILITIES.each do |util|
      assert_no_match(/@utility\s+#{Regexp.escape(util)}\s*\{/, css,
        "application.css re-declares @utility #{util}; it must be inherited from the " \
        "engine import instead (a local copy silently drifts, and for the token-driven " \
        "btn-secondary/btn-neutral it double-emits alongside the engine's rules)")
    end
  end

  test "[component] the kept @utility card delegates its base to the engine" do
    card = utility_block(APP_CSS.read, "card")
    assert card, "TM keeps a nested-only @utility card for its contextual tweaks; it went missing"
    assert_no_match(/@apply/, card,
      "@utility card must NOT @apply a base (bg-surface rounded-xl border border-subtle) — " \
      "the base comes from the engine import; only contextual selectors belong here")
    assert_match(/\.lp-splash\s*&/, card, "@utility card should keep its .lp-splash context rule")
    assert_match(/\.seeds-invite-row\s*&/, card, "@utility card should keep its .seeds-invite-row context rule")
  end

  test "[component] TM's violet secondary + neutral divergence is set via :root tokens" do
    css = APP_CSS.read
    # Violet secondary (bg-violet / bg-violet-600) instead of the engine's green default.
    assert_match(/--btn-secondary-bg:\s*#8e82fe/i, css,
      "TM's violet secondary must be set via --btn-secondary-bg (not a btn-secondary fork)")
    assert_match(/--btn-secondary-bg-hover:\s*#6558e5/i, css,
      "TM's secondary hover must be the violet-600 swap via --btn-secondary-bg-hover")
    assert_match(/--btn-secondary-hover-filter:\s*none/i, css,
      "TM's secondary swaps color on hover (no brightness filter) via --btn-secondary-hover-filter")
    # Neutral lightens in place (brightness 1.3), holding its surface-alt fill.
    assert_match(/--btn-neutral-hover-filter:\s*brightness\(1\.3\)/i, css,
      "TM's neutral hover brightens via --btn-neutral-hover-filter")
    assert_match(/--btn-neutral-bg-hover:\s*var\(--color-surface-alt\)/i, css,
      "TM pins --btn-neutral-bg-hover to surface-alt so the neutral fill holds on hover")
  end

  test "[component] the studio-engine build ships the utilities + the btn token contract" do
    engine_css = ENGINE_CSS.read
    %w[btn btn-primary btn-secondary btn-neutral card card-hover badge input-field empty-state].each do |util|
      assert_match(/@utility\s+#{Regexp.escape(util)}\s*\{/, engine_css,
        "studio-engine engine.css must define @utility #{util} for the app to inherit it")
    end
    # The token wiring TM's :root override depends on must actually exist upstream.
    assert_match(/--btn-secondary-bg\b/, engine_css,
      "engine btn-secondary must read --btn-secondary-bg for TM's violet override to take effect")
    assert_match(/--btn-neutral-hover-filter\b/, engine_css,
      "engine btn-neutral must read --btn-neutral-hover-filter for TM's brightness override to take effect")
  end
end
