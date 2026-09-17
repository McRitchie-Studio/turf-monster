require "test_helper"

# Component tier for the RGB-triple colour guard
# (task: legacy-rgba-glows-never-render).
#
# THE BUG. studio-engine emits every RGB-triple custom property as a
# SPACE-separated list: Studio::ThemeResolver#primary_palette_vars writes
# `--color-primary-500-rgb: 75 175 80`. The legacy comma form
# `rgba(var(--color-primary-500-rgb), 0.6)` substitutes to `rgba(75 175 80, 0.6)`,
# which mixes the space and comma syntaxes and is INVALID. A browser does not
# report it: the declaration is dropped at computed-value time and the property
# falls back to `none`. So the seeds-bar glow and the level-up glow painted
# nothing, in both themes, for as long as they had existed.
#
# MEASURED, not inferred. A static page loading the compiled stylesheet and the
# resolver's real theme vars, rendered in headless Chromium with each animation
# paused at 25 percent: `.level-up-pop` computed `box-shadow: none` before the fix
# and `rgba(75, 175, 80, 0.7) 0px 0px 40px 16px` after, the same under `html.dark`
# and without it. A comma-list var (`75, 175, 80`) in the legacy form DOES paint,
# which is why the form looks fine anywhere a comma list happens to be in scope.
#
# THE FIX is the slash form `rgb(var(--x-rgb) / A)`, which is valid for a space
# list and is what the rest of application.css and engine-motion.css write.
#
# WHY THE LEGACY FORM IS REFUSED OUTRIGHT rather than only where the var is a
# space list: every triple this app can resolve IS a space list, and the last
# test below pins that premise. A comma triple would have to be introduced on
# purpose, and the slash form still would not help it, so the refusal costs
# nothing and needs no var-by-var resolution to stay honest.
#
# levelGlow NOTE FOR THE NEXT PERSON: engine-motion.css ships a CORRECT
# `@keyframes levelGlow`, but application.css defines the same name after the
# engine import, and the later definition wins. That is how a broken copy hid a
# fixed one. The compiled-stylesheet scan below sees both.
class LegacyRgbaVarGuardTest < ActiveSupport::TestCase
  # `rgb(` or `rgba(`, then `var(--name)` (optionally with a fallback), then a
  # COMMA. The slash form puts `/` there and a bare `rgb(var(--x))` puts `)`, so
  # only the legacy form matches. Spaces are optional because the compiled
  # stylesheet is minified and the source is not.
  LEGACY_FORM = /rgba?\(\s*var\(\s*--[\w-]+(?:\s*,[^()]*)?\s*\)\s*,/

  SOURCE_GLOB = "app/**/*.{css,erb,js,rb}".freeze
  BUILDS_DIR  = Rails.root.join("app/assets/builds").to_s.freeze

  test "the detector bites the legacy form and passes the slash form" do
    legacy = [
      "box-shadow: 0 0 6px rgba(var(--color-primary-500-rgb), 0.3);",   # the shipped source line
      "box-shadow:0 0 6px rgba(var(--color-primary-500-rgb), .3)",      # as Tailwind minifies it
      "background: rgba( var( --color-primary-rgb ), 0.12 );",
      "color: rgb(var(--color-primary-rgb), 0.5)",
      "color: rgba(var(--glow-rgb, 1 2 3), 0.5)"
    ]
    legacy.each { |line| assert_match LEGACY_FORM, line, "detector missed: #{line}" }

    modern = [
      "box-shadow: 0 0 6px rgb(var(--color-primary-500-rgb) / 0.3);",
      "box-shadow:0 0 6px rgb(var(--color-primary-500-rgb) / .3)",
      "outline: 3px solid rgb(var(--color-primary-rgb));",
      "color: rgba(var(--color-primary-rgb) / 0.5)",
      "the legacy rgba(var(...), A) form is silently dropped" # the file's own warning prose
    ]
    modern.each { |line| assert_no_match LEGACY_FORM, line, "detector false positive: #{line}" }
  end

  test "the compiled stylesheet writes no legacy rgba(var(--x), A)" do
    css = CssClassGuard.stylesheet
    offenders = []
    css.scan(LEGACY_FORM) do
      at = Regexp.last_match.begin(0)
      offenders << "offset #{at}: #{css[[at - 60, 0].max, 140]}"
    end

    assert_empty offenders, <<~MSG
      app/assets/builds/tailwind.css carries the legacy comma form, which a browser
      silently DROPS for a space-separated RGB var (the glow or tint paints nothing).
      Rewrite each as rgb(var(--x-rgb) / A):
      #{offenders.join("\n")}
    MSG
  end

  test "no app source file writes legacy rgba(var(--x), A)" do
    # The compiled scan cannot see an inline style="" in a view, a style string a
    # helper builds, or JS that sets a style, so the source is read as well.
    files = Dir.glob(Rails.root.join(SOURCE_GLOB).to_s).reject { |p| p.start_with?(BUILDS_DIR) }
    assert_operator files.size, :>, 100, "source scan found too few files to mean anything"

    offenders = files.flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, index|
        next unless line.match?(LEGACY_FORM)
        "#{Pathname(path).relative_path_from(Rails.root)}:#{index + 1}: #{line.strip}"
      end
    end

    assert_empty offenders, <<~MSG
      Legacy rgba(var(--x), A) in app source. A space-separated RGB var makes it
      invalid, so the declaration drops and paints nothing. Use rgb(var(--x-rgb) / A):
      #{offenders.join("\n")}
    MSG
  end

  test "every RGB-triple var this app resolves is a space-separated list" do
    # The premise the refusal above rests on. If this ever fails, a comma triple
    # has entered the theme, and the refusal needs rethinking rather than a bypass.
    theme_css = Studio::ThemeResolver.new(Studio.theme_config).to_css
    definitions = (theme_css + CssClassGuard.stylesheet).scan(/(--[\w-]+-rgb)\s*:\s*([^;}]+)/)

    assert_operator definitions.count { |name, _| name.start_with?("--color-primary-") }, :>=, 10,
      "expected the resolver's primary palette triples; the scan is not reading them"

    commas = definitions.reject do |_name, value|
      value = value.strip
      value.match?(/\A\d{1,3} \d{1,3} \d{1,3}\z/) || value.start_with?("var(")
    end
    assert_empty commas.uniq, "RGB-triple vars that are not a space-separated list: #{commas.uniq.inspect}"
  end
end
