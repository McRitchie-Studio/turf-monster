require "test_helper"

# Component tier for green TEXT (task: primary-button-fails-contrast).
#
# The brand primary #2E7D32 is a FILL: white labels clear AA on it. As TEXT on
# the dark theme it measured 3.41:1 on the page and 2.18:1 on a card, so this
# app paints green text with a per-theme ink instead:
#
#   --color-primary-ink        dark #81C784, light = the primary
#   --color-primary-badge-ink  the ink for text ON a primary tint (level-badge-1)
#
# Declared at the end of app/assets/tailwind/application.css, and wired into
# `text-primary` by config/tailwind.config.js (textColor.primary).
#
# WHAT IS MEASURED. Nothing here trusts a hex. Each ratio resolves what ships:
#   * the COMPILED stylesheet (app/assets/builds/tailwind.css, which CI builds
#     before the suite) says which expression `.text-primary`, `.level-badge-1`
#     and `.text-success-ink` paint, and declares this app's ink tokens;
#   * the engine's emitted theme CSS (Studio::ThemeResolver#to_css over
#     ThemeSetting.current.resolved_colors, what studio_theme_css_tag renders)
#     supplies the primary, success and surface colours.
# The light theme is modelled the way the cascade builds it: html matches both
# `:root, .dark` and `html:not(.dark)`, and the second wins.
#
# THE BAR. Text must clear WCAG AA 4.5:1 on the card (--color-surface) and the
# page (--color-page), in both themes. Measured on 2026-09-16 and NOT asserted
# here: the light ink is 4.10:1 on bg-inset, and `bg-primary/15 text-primary`
# Tailwind badges are 4.21:1 in the light theme (docs/UI_PATTERNS.md, Still open).
class PrimaryTextContrastTest < ActiveSupport::TestCase
  AA_TEXT = 4.5
  COMPILED_CSS = Rails.root.join("app/assets/builds/tailwind.css").freeze
  VIEWS = Rails.root.join("app/views").freeze
  THEME_SELECTORS = { dark: ":root,.dark", light: "html:not(.dark)" }.freeze
  SURFACES = { card: "--color-surface", page: "--color-page" }.freeze

  # ── colour arithmetic, deliberately independent of Studio::ColorScale ──────

  def contrast(hex_a, hex_b)
    rel = lambda do |hex|
      r, g, b = rgb(hex).map { |c| c / 255.0 }
      lin = ->(v) { v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055)**2.4 }
      0.2126 * lin[r] + 0.7152 * lin[g] + 0.0722 * lin[b]
    end
    a, b = rel[hex_a], rel[hex_b]
    ([a, b].max + 0.05) / ([a, b].min + 0.05)
  end

  def rgb(hex)
    h = hex.delete("#")
    h = h.chars.map { |c| c * 2 }.join if h.length == 3
    h.scan(/../).map { |c| c.to_i(16) }
  end

  def hex(r, g, b) = format("#%02X%02X%02X", r.round, g.round, b.round)

  # Source-over compositing of a translucent colour onto an opaque one.
  def composite(top_hex, alpha, bottom_hex)
    hex(*rgb(top_hex).zip(rgb(bottom_hex)).map { |t, b| t * alpha + b * (1 - alpha) })
  end

  # ── what ships ─────────────────────────────────────────────────────────────

  def compiled_css
    @compiled_css ||= begin
      flunk "#{COMPILED_CSS} is missing — run `bin/rails tailwindcss:build` first" unless COMPILED_CSS.exist?
      COMPILED_CSS.read
    end
  end

  # Every leaf rule as [selector list without whitespace, body], in source order.
  def rules(css)
    css.scan(/([^{}]+)\{([^{}]*)\}/).map { |sel, body| [sel.gsub(/\s+/, ""), body] }
  end

  def declarations(body)
    body.scan(/(?<![\w-])(--[\w-]+|[a-z-]+)\s*:\s*([^;]+)/).to_h { |k, v| [k, v.strip] }
  end

  # The LAST rule whose selector list contains `selector` exactly, because that
  # is the one the cascade paints. The engine ships its own `.level-badge-1`
  # ahead of this app's, and this app's must be the one measured.
  def last_rule_for(selector, property, css = compiled_css)
    body = rules(css).select { |sel, b| sel.split(",").include?(selector) && declarations(b).key?(property) }.last&.last
    flunk "no compiled rule for #{selector} declares #{property}" unless body
    declarations(body)
  end

  def app_tokens(css, selector)
    rules(css).select { |sel, _| sel == selector }.map { |_, body| declarations(body) }.reduce({}, :merge)
  end

  def engine_tokens(mode, colors)
    css = Studio::ThemeResolver.new(colors).to_css
    block = css[/#{Regexp.escape(mode == :dark ? ":root, .dark" : "html:not(.dark)")}\s*\{([^}]*)\}/m, 1]
    flunk "the engine's theme CSS has no #{mode} block" unless block
    declarations(block)
  end

  # Custom properties an element sees in one theme: the engine's block plus
  # this app's, with the light theme layered over `:root, .dark` as the
  # cascade does. `overrides` lets a control swap one token and re-measure.
  def tokens(mode, css: compiled_css, colors: ThemeSetting.current.resolved_colors, overrides: {})
    dark = engine_tokens(:dark, colors).merge(app_tokens(css, THEME_SELECTORS[:dark]))
    seen = if mode == :dark
      dark
    else
      dark.merge(engine_tokens(:light, colors)).merge(app_tokens(css, THEME_SELECTORS[:light]))
    end
    seen.merge(overrides)
  end

  # Resolve a CSS colour expression to [hex, alpha].
  def resolve(expr, toks)
    value = expr.dup
    20.times do
      break unless value.include?("var(")

      value = value.gsub(/var\(\s*(--[\w-]+)\s*(?:,\s*([^()]*))?\)/) do
        toks.fetch(Regexp.last_match(1)) { Regexp.last_match(2) || flunk("#{Regexp.last_match(1)} is undefined in #{expr}") }
      end
    end
    case value.strip
    when /\A#\h{3}(\h{3})?\z/ then [value.strip, 1.0]
    when %r{\Argb\(\s*(\d+)\s+(\d+)\s+(\d+)\s*(?:/\s*([\d.]+))?\s*\)\z}
      [hex(Regexp.last_match(1).to_i, Regexp.last_match(2).to_i, Regexp.last_match(3).to_i),
       (Regexp.last_match(4) || "1").to_f]
    else
      flunk "cannot resolve #{expr.inspect} (reached #{value.inspect})"
    end
  end

  def opaque(expr, toks)
    color, alpha = resolve(expr, toks)
    assert_in_delta 1.0, alpha, 0.001, "#{expr} is translucent; measure it composited instead"
    color
  end

  def text_primary_ratios(mode, **opts)
    toks = tokens(mode, **opts)
    ink = opaque(last_rule_for(".text-primary", "color")["color"], toks)
    SURFACES.to_h { |name, var| [name, [contrast(ink, opaque(toks.fetch(var), toks)), ink]] }
  end

  def level_badge_ratios(mode, **opts)
    toks = tokens(mode, **opts)
    decl = last_rule_for(".level-badge-1", "color")
    ink = opaque(decl["color"], toks)
    tint, alpha = resolve(decl.fetch("background"), toks)
    SURFACES.to_h do |name, var|
      ground = composite(tint, alpha, opaque(toks.fetch(var), toks))
      [name, [contrast(ink, ground), ink, ground]]
    end
  end

  # ── text-primary ───────────────────────────────────────────────────────────

  test "text-primary paints the ink while bg-primary keeps the fill" do
    fill = opaque(last_rule_for(".bg-primary", "background-color")["background-color"], tokens(:dark))
    ink  = opaque(last_rule_for(".text-primary", "color")["color"], tokens(:dark))
    assert_equal "#2E7D32", fill.upcase, "bg-primary must stay the brand fill"
    refute_equal fill.upcase, ink.upcase,
                 "text-primary resolves to the fill #{fill} in the dark theme; it must read --color-primary-ink"
  end

  test "text-primary clears AA on the card and the page in both themes" do
    THEME_SELECTORS.each_key do |mode|
      text_primary_ratios(mode).each do |surface, (ratio, ink)|
        assert_operator ratio, :>=, AA_TEXT,
                        "text-primary (#{ink}) on the #{mode} #{surface} is #{format('%.2f', ratio)}:1; AA needs 4.5:1"
      end
    end
  end

  test "control: without the dark ink, text-primary fails on the dark card" do
    ratio, ink = text_primary_ratios(:dark, overrides: { "--color-primary-ink-rgb" => "var(--color-primary-rgb)" })[:card]
    assert_equal "#2E7D32", ink.upcase, "the control must measure the bare primary"
    assert_in_delta 2.18, ratio, 0.01, "the bare primary on the dark card measured 2.18:1 when this was built"
  end

  test "control: the dark ink cannot serve the light theme" do
    ratio, = text_primary_ratios(:light, overrides: { "--color-primary-ink-rgb" => "129 199 132" })[:card]
    assert_operator ratio, :<, AA_TEXT, "#81C784 on white is #{format('%.2f', ratio)}:1; the ink must stay per theme"
  end

  # ── text on a primary tint: .level-badge-1 ───────────────────────────────────

  test "level-badge-1 clears AA on its own tint over the card and the page in both themes" do
    THEME_SELECTORS.each_key do |mode|
      level_badge_ratios(mode).each do |surface, (ratio, ink, ground)|
        assert_operator ratio, :>=, AA_TEXT,
                        "level-badge-1 (#{ink} on #{ground}) over the #{mode} #{surface} is " \
                        "#{format('%.2f', ratio)}:1; AA needs 4.5:1 for its 10px label"
      end
    end
  end

  test "control: the plain light ink fails on the level-badge-1 tint" do
    ratio, = level_badge_ratios(:light, overrides: { "--color-primary-badge-ink" => "var(--color-primary-ink)" })[:card]
    assert_operator ratio, :<, AA_TEXT,
                    "the primary on its own 15 percent tint is #{format('%.2f', ratio)}:1, which is why the badge ink exists"
  end

  # ── hand-written green text cannot bypass the ink ────────────────────────────

  test "no view paints text with the primary fill tokens" do
    offenders = Dir[VIEWS.join("**/*.erb")].flat_map do |path|
      File.readlines(path).each_with_index.filter_map do |line, i|
        "#{path.delete_prefix("#{Rails.root}/")}:#{i + 1}" if line.match?(/(?<![\w-])color:\s*var\(--color-(cta|primary)\)/)
      end
    end
    assert_empty offenders,
                 "these paint text with a FILL token, which is 2.18:1 on a dark card. " \
                 "Use var(--color-primary-ink) (or --color-primary-badge-ink on a primary tint)."
  end

  # The navbar balance links hover to a FILL shade on bg-page (and the card-toned
  # peek pill). On #2E7D32 the 600 shade is 2.65:1 on the dark page, where the old
  # primary's was 4.66:1, so the dark theme hovers to the 300 shade instead.
  test "the navbar balance links hover to an AA ink on the page and card in both themes" do
    links = Rails.root.join("app/views/layouts/_navbar.html.erb").read.scan(/class: "(?:nav-balance|free-entry-label) ([^"#]*)/).flatten
    assert_equal 2, links.size, "expected the nav-balance and free-entry-label links"
    { light: "hover:text-primary-600", dark: "dark:hover:text-primary-300" }.each do |mode, klass|
      links.each { |classes| assert_includes classes.split, klass, "a navbar balance link lost its #{mode} hover" }
      selector = ".#{klass.gsub(':', '\:')}"
      body = rules(compiled_css).select { |sel, b| sel.start_with?("#{selector}:") && declarations(b).key?("color") }.last&.last
      flunk "no compiled hover rule for #{klass}" unless body
      toks = tokens(mode)
      ink = opaque(declarations(body)["color"], toks)
      SURFACES.each_value do |var|
        ratio = contrast(ink, opaque(toks.fetch(var), toks))
        assert_operator ratio, :>=, AA_TEXT, "#{klass} (#{ink}) on the #{mode} #{var} is #{format('%.2f', ratio)}:1"
      end
    end
  end

  # ── success as text ──────────────────────────────────────────────────────────

  test "text-success-ink clears AA on the card, the page and its own tint in both themes" do
    THEME_SELECTORS.each_key do |mode|
      toks = tokens(mode)
      ink = opaque(last_rule_for(".text-success-ink", "color")["color"], toks)
      success = opaque(toks.fetch("--color-success"), toks)
      SURFACES.each do |surface, var|
        ground = opaque(toks.fetch(var), toks)
        { "bare" => ground, "bg-success/10" => composite(success, 0.10, ground) }.each do |label, bg|
          ratio = contrast(ink, bg)
          assert_operator ratio, :>=, AA_TEXT,
                          "text-success-ink (#{ink}) on the #{mode} #{surface} (#{label}, #{bg}) is #{format('%.2f', ratio)}:1"
        end
      end
    end
  end
end
