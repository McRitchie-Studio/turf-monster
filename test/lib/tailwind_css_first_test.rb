require "test_helper"

# Turf builds Tailwind CSS-first (task turf-adopts-css-first-tailwind; the
# recipe is studio-engine's README, "Tailwind", and CHANGELOG 0.114.2). The
# whole engine layer arrives through ONE line of app/assets/tailwind/application.css:
#
#     @import "../builds/tailwind/studio_engine";
#
# tailwindcss-rails writes that gitignored entry on every build, and
# Studio::TailwindEntry points it at the gem's host.css, which imports the
# theme tokens (theme.css), @source-scans the gem, and imports the motion layer
# (engine-motion.css). Turf's own theme extensions are the `@theme inline
# reference` block in application.css.
#
# This guard fails if the JS config comes back in any form: a
# config/tailwind.config.js, an `@config` (or `@plugin`) pointing at one, the
# engine's deprecated studio.tailwind.config.js preset, or the old per-app
# motion import and its rake task. Each is a quiet regression rather than an
# error: the preset is a one-release shim that the engine deletes, the old
# motion import doubles the motion layer, and Tailwind 4 ignores a JS
# `safelist`, so a safelist there looks like protection and compiles nothing.
class TailwindCssFirstTest < ActiveSupport::TestCase
  ROOT = Rails.root
  APP_CSS = ROOT.join("app/assets/tailwind/application.css")
  ENGINE_ENTRY = ROOT.join("app/assets/builds/tailwind/studio_engine.css")
  COMPILED_CSS = ROOT.join("app/assets/builds/tailwind.css")
  CSS_SOURCES = Dir[ROOT.join("app/assets/tailwind/**/*.css")].freeze

  # Comments go first: application.css explains, in prose, that there is no
  # @config, and a guard that matched the explanation would be red forever.
  def directives(path) = File.read(path).gsub(%r{/\*.*?\*/}m, "")

  def imports(path)
    directives(path).scan(/@import\s+["']([^"']+)["']/).flatten
  end

  # Every stylesheet application.css pulls in, transitively, through relative
  # or absolute @imports (`tailwindcss` itself is the package, not a file).
  def import_graph(path, seen = [])
    seen << path.to_s
    imports(path).each do |ref|
      next if ref == "tailwindcss"

      target = Pathname.new(ref).absolute? ? Pathname.new(ref) : Pathname.new(path).dirname.join(ref)
      target = Pathname.new("#{target}.css") unless target.extname == ".css"
      assert target.exist?, "#{path} imports #{ref}, which resolves to #{target}, a file that does not exist"
      import_graph(target.cleanpath, seen)
    end
    seen
  end

  def built!(path)
    flunk "#{path} is missing — run `bin/rails tailwindcss:build` first" unless path.exist?
  end

  test "the guard reads the sources it guards" do
    assert_includes CSS_SOURCES, APP_CSS.to_s
    # Control: the comment stripper must not eat the directives themselves.
    assert_includes imports(APP_CSS), "tailwindcss"
  end

  test "there is no JS Tailwind config" do
    configs = Dir[ROOT.join("{,config/}tailwind.config.{js,cjs,mjs,ts}")]
    assert_empty configs, "Turf builds Tailwind CSS-first; move these into application.css's @theme block"
  end

  test "no stylesheet reintroduces @config, a JS plugin or the engine preset" do
    CSS_SOURCES.each do |path|
      css = directives(path)
      refute css.match?(/@config\b/), "#{path} has an @config directive"
      refute css.match?(/@plugin\s+["'][^"']*\.(c|m)?js["']/), "#{path} loads a JS plugin"
      refute css.match?(/studio\.tailwind\.config/), "#{path} names the engine's deprecated preset"
      refute css.match?(/studio_engine_motion/), "#{path} imports the old per-app motion entry"
    end
  end

  test "the old motion rake task is gone" do
    refute ROOT.join("lib/tasks/tailwindcss_engine_motion.rake").exist?
    offenders = Dir[ROOT.join("lib/tasks/**/*.rake")].select { |f| File.read(f).include?("engine-motion.css") }
    assert_empty offenders, "a rake task generates an engine-motion entry again; host.css imports it already"
  end

  test "application.css opens with tailwindcss and the engine entry" do
    assert_equal %w[tailwindcss ../builds/tailwind/studio_engine], imports(APP_CSS).first(2)
  end

  test "Turf's theme extensions live in a reference-only @theme block" do
    css = directives(APP_CSS)
    theme = css[/@theme\s+inline\s+reference\s*\{(.*?)\}/m, 1]
    refute_nil theme, "application.css has no `@theme inline reference` block"
    {
      "--breakpoint-pill-narrow" => "530px",
      "--text-color-primary" => "rgb(var(--color-primary-ink-rgb))",
      "--text-color-violet-ink" => "var(--color-violet-ink)",
      "--color-warning-500" => "#FF7C47",
    }.each do |token, value|
      assert_match(/#{Regexp.escape(token)}:\s*#{Regexp.escape(value)};/, theme, "#{token} is not #{value}")
    end
    # A plain (non-reference) @theme would declare these on :root and race the
    # runtime custom properties studio_theme_css_tag writes.
    refute css.match?(/@theme(?!\s+inline\s+reference)\s*[{a-z]/), "application.css has a @theme that is not inline reference"
  end

  test "the engine entry resolves to host.css and the motion layer is imported exactly once" do
    built!(ENGINE_ENTRY)
    graph = import_graph(APP_CSS)
    assert graph.any? { |p| p.end_with?("studio_engine/host.css") },
           "the engine entry does not reach host.css (studio-engine < 0.114.2?): #{graph.inspect}"
    assert graph.any? { |p| p.end_with?("studio_engine/theme.css") }, "theme.css is not imported"
    motion = graph.count { |p| p.end_with?("engine-motion.css") }
    assert_equal 1, motion, "engine-motion.css is imported #{motion} times: #{graph.inspect}"
  end

  test "the compiled stylesheet carries the engine tokens, Turf's extensions and the motion layer" do
    built!(COMPILED_CSS)
    css = COMPILED_CSS.read
    {
      "theme.css surface token" => ".bg-surface{background-color:var(--color-surface)}",
      "theme.css heading ink" => ".text-heading{color:var(--color-text)}",
      "Turf's text-primary ink" => ".text-primary{color:rgb(var(--color-primary-ink-rgb))}",
      "Turf's violet ink" => ".text-violet-ink{color:var(--color-violet-ink)}",
      "Turf's warning palette" => ".bg-warning-500{background-color:#ff7c47}",
      "Turf's pill-narrow screen" => "@media (min-width:530px){.pill-narrow\\:inline{display:inline}}",
      "engine-motion .spinner" => ".spinner{",
    }.each do |what, rule|
      assert_includes css, rule, "the compiled CSS lost the #{what}"
    end
  end
end
