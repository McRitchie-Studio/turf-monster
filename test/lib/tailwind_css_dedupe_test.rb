require "test_helper"

# Regression guard for the 2026-07 application.css dedupe (task
# dedupe-turf-application-css). The Tailwind v4 migration left ~40% of the
# file self-duplicated: the hold-button component existed twice (once inside
# @utility hold-btn, once as eight bare utilities), .nav-emoji-swap and the
# toast z-index vars were defined both unlayered and inside @layer utilities,
# and @utility px-1 shadowed the core Tailwind utility with an identical
# value. These tests assert the positive invariants so any re-introduced
# duplicate fails loudly, whatever its spelling.
class TailwindCssDedupeTest < ActiveSupport::TestCase
  CSS_PATH = Rails.root.join("app/assets/tailwind/application.css")

  def css
    @css ||= File.read(CSS_PATH)
  end

  test "every @utility name is defined exactly once" do
    names = css.scan(/^@utility\s+([\w-]+)\s*\{/).flatten
    dupes = names.tally.select { |_, count| count > 1 }
    assert_empty dupes, "duplicate @utility definitions: #{dupes.keys.join(', ')}"
  end

  test "hold-button state classes are not bare utilities" do
    # process/success/error/loading/nudge/nudge-soft are JS-applied state hooks.
    # Bare utilities with these common names get emitted whenever the token
    # appears anywhere Tailwind scans (flash[:success], prose, JS strings).
    #
    # The hold button itself moved to studio-engine 0.56, so this guard now has a
    # SECOND job: the engine ships these rules UNLAYERED, and an @utility here
    # would compile into @layer utilities and silently lose to them. Re-declaring
    # any of these locally is therefore worse than duplication — it is dead CSS
    # that reads as live.
    %w[process success error loading nudge nudge-soft hold-icon hold-text fizz hold-fizz fizz-bit].each do |name|
      refute_match(/^@utility\s+#{Regexp.escape(name)}\s*\{/, css,
        "@utility #{name} reintroduced — hold-button states belong inside @utility hold-btn")
    end
  end

  test "no @utility shadows a core Tailwind spacing or sizing utility" do
    # e.g. @utility px-1 overrode core px-1 (with an identical value). Core
    # names look like p/px/py/m/mx/my/w/h/gap-<number>.
    core_shaped = css.scan(/^@utility\s+((?:p|px|py|pt|pr|pb|pl|m|mx|my|mt|mr|mb|ml|w|h|gap|text|space-x|space-y)-\d[\w.]*)\s*\{/).flatten
    assert_empty core_shaped, "@utility overriding core Tailwind utilities: #{core_shaped.join(', ')}"
  end

  test "hand-written selectors appear exactly once" do
    {
      ".nav-emoji-swap {" => "nav emoji swap block"
    }.each do |needle, label|
      assert_equal 1, css.scan(needle).size, "#{label} (#{needle.inspect}) must be defined exactly once"
    end
  end

  # THE INVARIANT ON AN OVERRIDE SEAM IS "NEVER TWICE", NOT "EXACTLY ONCE", and
  # separating the two is what the layer-scale shim deletion forced (task
  # delete-turf-layer-shim). These names are studio-engine's published per-
  # component override seam. This app only ever set them from inside the adoption
  # shim, and the engine's own layouts/studio/_flash now defaults both to the
  # shared --z-toast / --z-toast-blur tiers — so with the shim gone this app
  # declares NEITHER, and that zero is correct rather than a regression.
  #
  # An exact-count assertion read that zero as a failure, which is the same trap
  # the adoption suite fell into: a test that REQUIRES a local copy cements the
  # local copy. Deleting these needles instead would have thrown away the dedupe
  # guard this file exists for, so they keep it in the form that is actually true
  # of an optional override — declared at most once, because a second declaration
  # wins over the first in silence.
  test "an engine override seam is never declared twice" do
    {
      "--studio-toast-z:" => "toast z-index override",
      "--studio-toast-blur-z:" => "toast blur z-index override"
    }.each do |needle, label|
      assert_operator css.scan(needle).size, :<=, 1,
        "#{label} (#{needle.inspect}) is declared more than once — the later declaration " \
        "silently wins, and the earlier one reads as live CSS while doing nothing"
    end
  end
end
