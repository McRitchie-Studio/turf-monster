require "test_helper"

# [component] THE TWO NON-COSMETIC PHANTOM-CLASS SITES, AND THE LIMIT OF THE
# GUARD THAT COVERS ONE OF THEM.
#
# A class name no stylesheet defines paints NOTHING, and nothing else in this
# suite can see it: not a Ruby error, not an ERB error, not a failing request
# spec, not a broken link. The page returns 200 and the tests stay green.
#
# Two sites here were singled out from the wider phantom survey because they
# are not cosmetic:
#
#   1. admin/pending_transactions — a COSIGNER SELECT on a signing surface wore
#      `select select-bordered select-xs`, none of which this app defines
#      (DaisyUI vocabulary; there is no DaisyUI here). An operator choosing who
#      co-signs a treasury transaction got a control with no visible boundary.
#      Fixed to `input-field`, the same primitive the identical control on
#      admin/vault_state/show.html.erb already uses.
#
#   2. accounts/confirm_email_change — the CTA wore `bg-primary
#      text-on-primary`. The FILL resolved and the LABEL COLOUR did not, so a
#      user arriving from an email met a filled green button whose label took
#      whatever ink it inherited. Fixed to `btn btn-primary`.
#
# ── WHY THERE ARE TWO DIFFERENT TESTS BELOW, AND WHY THAT IS NOT OPTIONAL ──
#
# CssClassGuard.class_literals_in_erb reads HTML `class="…"` ATTRIBUTES. Site 2
# is not written that way — it is `class:` passed as a Ruby option to
# `button_to`, which the reader's `class=` pattern cannot match. So:
#
#     A GREEN GUARD DOES NOT PROVE SITE 2 IS FIXED. It never could.
#
# The guard test covers site 1. Site 2 is covered by a SECOND test that renders
# the page and asserts the button carries a class that actually declares a
# colour — a question the source-reading guard cannot ask. Each test carries a
# control, because a test that silently proves nothing is the exact failure
# mode this whole task exists to catch.
class PhantomClassesRemainingTest < ActiveSupport::TestCase
  GUARDED_VIEWS = %w[
    app/views/admin/pending_transactions/index.html.erb
    app/views/accounts/confirm_email_change.html.erb
  ].freeze

  # ── SITE 1 ───────────────────────────────────────────────────────────────
  # Reads the TEMPLATE, not a rendered body: the cosign controls sit behind
  # `tx.pending?` / `extras_needed.positive?` / `@eligible_extras.any?`, and a
  # render only exercises the branch the test stubs. The source carries them
  # all at once.
  test "neither view names a class the stylesheet leaves undefined" do
    offenders = GUARDED_VIEWS.flat_map do |relative|
      path = Rails.root.join(relative)
      assert path.exist?, "#{relative} is gone — this guard would pass vacuously"

      literals = CssClassGuard.class_literals_in_erb(path)
      assert literals.any?, "#{relative} yielded no class literals at all — the reader is broken"

      literals.reject { |name, _| CssClassGuard.defined_in_css?(name) }
              .map { |name, line| "#{relative}:#{line} #{name}" }
    end

    assert_empty offenders,
                 "these classes are in the markup and absent from the stylesheet, " \
                 "so they paint nothing:\n  #{offenders.join("\n  ")}"
  end

  # THE CONTROL FOR SITE 1. Without it the guard above would pass against a
  # stylesheet that defines nothing at all, or against a reader that returns
  # every name as defined.
  test "the retired select phantoms still read as undefined" do
    %w[select select-bordered select-xs text-error text-base-content/70].each do |retired|
      assert_not CssClassGuard.defined_in_css?(retired),
                 "#{retired} was removed from the cosign controls and must still read as " \
                 "UNDEFINED — if it resolves now, the guard above proves nothing"
    end
    assert CssClassGuard.defined_in_css?("input-field"),
           "the field primitive the select now wears must read as defined, " \
           "or the guard above is unsatisfiable"
    assert CssClassGuard.defined_in_css?("text-danger-ink"),
           "the app's error-ink utility must read as defined"
  end

  # ── THE GUARD'S BLIND SPOT, STATED AS A TEST ─────────────────────────────
  #
  # This is the finding, pinned so it cannot quietly stop being true. If
  # someone later teaches the reader to parse `class:` helper options, this
  # test fails and whoever changes it must re-read the comment above and decide
  # whether the rendered-CTA test below is still needed. That is the intended
  # outcome, not a nuisance.
  test "the source reader cannot see a class list written as a Ruby helper option" do
    path = Rails.root.join("app/views/accounts/confirm_email_change.html.erb")
    source = File.read(path)

    assert_match(/class:\s*"btn btn-primary/, source,
                 "the CTA's class list must still be a `class:` helper option, " \
                 "or this test is describing markup that no longer exists")

    seen = CssClassGuard.class_literals_in_erb(path).map(&:first)
    assert_not_includes seen, "btn-primary",
                        "class_literals_in_erb reads HTML class=\"…\" attributes only. If it " \
                        "now sees a `class:` helper option, the blind spot this task documented " \
                        "is closed — re-read this file's header and revisit the rendered-CTA test."
  end
end
