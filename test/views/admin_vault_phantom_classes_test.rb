require "test_helper"

# [component] THE TWO VAULT-AUTHORITY PAGES NAME NO CLASS THE STYLESHEET
# LEAVES UNDEFINED.
#
# A missing CSS class is invisible to every other guard in this suite. It is
# not a Ruby error, not an ERB error, not a failing request spec, not a broken
# link. The page returns 200, the suite stays green, and the field paints
# nothing. It is visible only to a human looking at the rendered page, which is
# how the same defect was found on /admin/authorities.
#
# `input input-bordered` shipped on both pages below — eight occurrences —
# and NEITHER class exists here; the engine's primitive is `input-field`. Both
# pages are vault-authority surfaces: a field an operator types a PUBKEY into,
# rendering with no visible boundary, is a place to mistype a key that controls
# money.
#
# WHY THIS READS THE TEMPLATE RATHER THAN A RENDERED BODY. A render only
# exercises the branch the test stubs, and vault_state alone has three whose
# fields differ (paused, paused with no spare signer, unpaused). Reading the
# source covers every branch at once and keeps the guard green as the
# controllers evolve — the question is about the MARKUP, so the markup is what
# it reads.
class AdminVaultPhantomClassesTest < ActiveSupport::TestCase
  GUARDED_VIEWS = %w[
    app/views/admin/vault_state/show.html.erb
    app/views/admin/vault_init/show.html.erb
  ].freeze

  test "the vault pages name no class the stylesheet leaves undefined" do
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

  # THE CONTROL FOR THE PAIR THAT SHIPPED. Without it this guard would pass
  # against a stylesheet that defines nothing at all.
  test "the retired phantom pair still reads as undefined" do
    assert_not CssClassGuard.defined_in_css?("input-bordered"),
               "the retired phantom must still read as undefined, or the guard is inert"
    assert_not CssClassGuard.defined_in_css?("input"),
               "`input` is the other half of the retired pair and is equally undefined"
    assert CssClassGuard.defined_in_css?("input-field"),
           "the engine field primitive must read as defined, or the guard is unsatisfiable"
  end

  # ── THE PREFIX HOLE ──────────────────────────────────────────────────────
  #
  # The first version of this guard asked `css.include?(".#{name}")`. A plain
  # substring match reports a PREFIX of a real class as DEFINED, because
  # `.text-danger` is a substring of `.text-danger-ink`. Measured on the
  # shipped guard (PR 726): `text-danger` and `bg-transp` were both added to
  # live markup and the guard stayed GREEN.
  #
  # It is not a hypothetical shape. `input` — half of the very pair this task
  # exists to remove — is a prefix of the real `.input-field`, so the guard
  # that caught `input-bordered` could never have caught its partner.
  #
  # These two tests fail against `include?` and pass against the boundary
  # regex, which is the only reason they are worth their lines.

  test "a class that is only a PREFIX of a real one reads as undefined" do
    # Carl's two, measured against this app's real compiled stylesheet.
    { "text-danger" => "text-danger-ink", "bg-transp" => "bg-transparent" }.each do |prefix, real|
      assert CssClassGuard.defined_in_css?(real),
             "#{real} must be defined, or the pair below proves nothing"
      assert_not CssClassGuard.defined_in_css?(prefix),
                 "#{prefix} is only a prefix of #{real} and defines no rule of its own — " \
                 "a substring match reports it as defined and lets a phantom through"
    end
  end

  test "the boundary holds at both ends of a selector" do
    # Stated against a fixed stylesheet rather than the compiled one, so the
    # LOGIC is pinned even as Tailwind's output churns.
    sheet = ".text-danger-ink{color:red}.p-1\\.5{padding:6px}.md\\:flex{display:flex}.foo\\.bar{color:blue}"

    assert CssClassGuard.defined_in_css?("text-danger-ink", sheet)
    assert_not CssClassGuard.defined_in_css?("text-danger", sheet),
               "a prefix must not match the longer class it starts"

    # An ESCAPE continues the identifier: `.p-1\.5` is the class `p-1.5`.
    assert CssClassGuard.defined_in_css?("p-1.5", sheet)
    assert_not CssClassGuard.defined_in_css?("p-1", sheet),
               "a backslash continues the name, so `p-1` is not defined by `.p-1\\.5`"

    # A leading escaped dot is part of a name, not the start of a selector.
    assert CssClassGuard.defined_in_css?("foo.bar", sheet)
    assert_not CssClassGuard.defined_in_css?("bar", sheet),
               "`.bar` inside `.foo\\.bar` is an escaped dot, not a class selector"

    # Escaped characters still resolve, or every variant would read phantom.
    assert CssClassGuard.defined_in_css?("md:flex", sheet)
  end
end
