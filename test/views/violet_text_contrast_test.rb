require "test_helper"

# Component tier for violet TEXT (task: fix-violet-text-contrast).
#
# The brand violet #8E82FE is a FILL: it paints backgrounds, borders, rings and
# chart strokes, and it is the colour people recognise as Turf Monster's accent.
# As SMALL TEXT it fails WCAG AA both ways round — 3.10:1 on the light card and
# 3.60:1 on the dark card (found by Shannon reviewing PR 774, 2026-09-19, on the
# /benchmarks Turf Score column). So small violet text reads a separate ink:
#
#   --color-violet-ink   dark #C5C0FE (the ramp's violet-300)
#                        light #5B50CE (violet-600 darkened 10 percent)
#
# Declared at the end of app/assets/tailwind/application.css and wired to
# `text-violet-ink` by config/tailwind.config.js (textColor). The brand token is
# untouched, which is the whole point: `bg-violet`, `border-violet` and large
# display type still paint #8E82FE.
#
# WHAT IS MEASURED. Nothing here trusts a hex. Every ratio resolves what ships:
#   * the COMPILED stylesheet (app/assets/builds/tailwind.css, which CI builds
#     before the suite) says what `.text-violet-ink`, `.text-violet`,
#     `.bg-violet` and `.bg-violet/10|20` actually paint, and declares this
#     app's ink tokens;
#   * the engine's emitted theme CSS (Studio::ThemeResolver#to_css over
#     ThemeSetting.current.resolved_colors) supplies the four surfaces.
# The light theme is modelled the way the cascade builds it: html matches both
# `:root, .dark` and `html:not(.dark)`, and the second wins.
#
# THE BAR. Small violet text must clear AA 4.5:1 in BOTH themes on the four
# theme surfaces AND inside the two violet-tinted badges this app actually
# writes (`bg-violet/10` and `bg-violet/20` over the card and the page), because
# those badges carry 10px and 12px labels.
#
# MEASURED AND NOT ASSERTED, because both are FILL defects the ink cannot reach:
#   * `bg-violet-900/30` (CONTEST_BADGE_STYLES "pending") composites to a pale
#     lavender in the light theme, where the ink is 3.50:1 — up from the brand
#     violet's 1.80:1, but still short. Its mint, yellow and red siblings share
#     the defect, so the fix is the badge family, not this token.
#   * `hover:bg-violet/30` on the wallets airdrop button is 4.46:1 light and
#     4.38:1 dark; the rest state (`bg-violet/20`) clears.
class VioletTextContrastTest < ActiveSupport::TestCase
  AA_TEXT = 4.5
  COMPILED_CSS = Rails.root.join("app/assets/builds/tailwind.css").freeze
  SCANNED = [ Rails.root.join("app/views"), Rails.root.join("app/helpers") ].freeze
  THEME_SELECTORS = { dark: ":root,.dark", light: "html:not(.dark)" }.freeze
  SURFACES = {
    card: "--color-surface", page: "--color-page",
    "surface-alt": "--color-surface-alt", inset: "--color-inset"
  }.freeze
  # The violet tints small labels sit inside, and the surfaces they sit on.
  TINT_CLASSES = [ ".bg-violet\\/10", ".bg-violet\\/20" ].freeze
  TINT_SURFACES = { card: "--color-surface", page: "--color-page" }.freeze

  # Bare `text-violet` is the FILL. These are the only places it may still paint
  # text, with the reason it is allowed and how many times it appears there. A
  # new bare use anywhere else fails this test; a new one HERE bumps the count
  # and fails too, so the exemption cannot quietly grow.
  BARE_TEXT_VIOLET_ALLOWED = {
    # WCAG large text (>= 24px, or >= 18.66px bold) clears at 3:1, and the brand
    # violet does: 3.60:1 on the dark card, 3.10:1 on the light card.
    "app/views/pages/turf_totals_v1.html.erb" => 5,
    "app/views/pages/turf_monster_v1.html.erb" => 2,
    "app/views/admin/scoring/index.html.erb" => 1,
    "app/views/games/index.html.erb" => 1,
    # Not text: a 4x4 status dot whose label is sr-only. It is a graphical
    # object under WCAG 1.4.11 (3:1), and it already picks its shade per theme
    # on purpose — violet-600 on light surfaces, the base violet on dark.
    "app/views/admin/pending_transactions/_signer_roster.html.erb" => 2
  }.freeze

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

  # Source-over compositing of a translucent colour onto an opaque one, in
  # GAMMA-ENCODED sRGB, the way a browser paints it. A linear-light blend gives
  # a different ground and a wrong ratio (see docs/UI_PATTERNS.md).
  def composite(top_hex, alpha, bottom_hex)
    hex(*rgb(top_hex).zip(rgb(bottom_hex)).map { |t, b| t * alpha + b * (1 - alpha) })
  end

  # Tailwind v4 emits every opacity variant in oklab(), so `bg-violet/20` is not
  # a hex. Converting it back is what lets the tint grounds be read from the
  # COMPILED rule rather than from a hex retyped here.
  def oklab_to_hex(lightness, a_axis, b_axis)
    l = (lightness + 0.3963377774 * a_axis + 0.2158037573 * b_axis)**3
    m = (lightness - 0.1055613458 * a_axis - 0.0638541728 * b_axis)**3
    s = (lightness - 0.0894841775 * a_axis - 1.2914855480 * b_axis)**3
    linear = [
      4.0767416621 * l - 3.3077115913 * m + 0.2309699292 * s,
      -1.2684380046 * l + 2.6097574011 * m - 0.3413193965 * s,
      -0.0041960863 * l - 0.7034186147 * m + 1.7076147010 * s
    ]
    hex(*linear.map do |v|
      v = v.clamp(0.0, 1.0)
      255 * (v <= 0.0031308 ? 12.92 * v : 1.055 * (v**(1 / 2.4)) - 0.055)
    end)
  end

  # ── what ships ─────────────────────────────────────────────────────────────

  def compiled_css
    @compiled_css ||= begin
      flunk "#{COMPILED_CSS} is missing — run `bin/rails tailwindcss:build` first" unless COMPILED_CSS.exist?
      COMPILED_CSS.read
    end
  end

  def rules(css)
    css.scan(/([^{}]+)\{([^{}]*)\}/).map { |sel, body| [ sel.gsub(/\s+/, ""), body ] }
  end

  def declarations(body)
    body.scan(/(?<![\w-])(--[\w-]+|[a-z-]+)\s*:\s*([^;]+)/).to_h { |k, v| [ k, v.strip ] }
  end

  # The LAST rule whose selector list contains `selector` exactly, because that
  # is the one the cascade paints.
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
    when /\A#\h{3}(\h{3})?\z/ then [ value.strip, 1.0 ]
    when %r{\Argb\(\s*(\d+)\s+(\d+)\s+(\d+)\s*(?:/\s*([\d.]+))?\s*\)\z}
      [ hex(Regexp.last_match(1).to_i, Regexp.last_match(2).to_i, Regexp.last_match(3).to_i),
        (Regexp.last_match(4) || "1").to_f ]
    when %r{\Aoklab\(\s*([\d.]+)%\s+(-?[\d.]+)\s+(-?[\d.]+)\s*(?:/\s*([\d.]+))?\s*\)\z}
      [ oklab_to_hex(Regexp.last_match(1).to_f / 100.0, Regexp.last_match(2).to_f, Regexp.last_match(3).to_f),
        (Regexp.last_match(4) || "1").to_f ]
    else
      flunk "cannot resolve #{expr.inspect} (reached #{value.inspect})"
    end
  end

  def opaque(expr, toks)
    color, alpha = resolve(expr, toks)
    assert_in_delta 1.0, alpha, 0.001, "#{expr} is translucent; measure it composited instead"
    color
  end

  # Every ground small violet text lands on, in one theme: the four bare
  # surfaces, plus each violet tint composited over the card and the page.
  def grounds(mode, **opts)
    toks = tokens(mode, **opts)
    out = SURFACES.to_h { |name, var| [ name.to_s, opaque(toks.fetch(var), toks) ] }
    TINT_CLASSES.each do |klass|
      tint, alpha = resolve(last_rule_for(klass, "background-color", compiled_css)["background-color"], toks)
      assert_operator alpha, :<, 1.0, "#{klass} is opaque; the tint grounds assume a wash"
      TINT_SURFACES.each do |name, var|
        out["#{klass.delete('\\').delete_prefix('.')} on #{name}"] = composite(tint, alpha, opaque(toks.fetch(var), toks))
      end
    end
    out
  end

  def ink_ratios(mode, selector: ".text-violet-ink", **opts)
    toks = tokens(mode, **opts)
    ink = opaque(last_rule_for(selector, "color")["color"], toks)
    [ ink, grounds(mode, **opts).transform_values { |bg| [ contrast(ink, bg), bg ] } ]
  end

  # ── the fill stays the fill ────────────────────────────────────────────────

  test "text-violet-ink paints an ink while bg-violet and text-violet keep the brand fill" do
    fill = opaque(last_rule_for(".bg-violet", "background-color")["background-color"], tokens(:dark))
    assert_equal "#8E82FE", fill.upcase, "bg-violet must stay the brand fill"
    assert_equal fill.upcase, opaque(last_rule_for(".text-violet", "color")["color"], tokens(:dark)).upcase,
                 "text-violet is the FILL used as large type; it must not be rerouted"

    THEME_SELECTORS.each_key do |mode|
      ink, = ink_ratios(mode)
      refute_equal fill.upcase, ink.upcase,
                   "text-violet-ink resolves to the fill #{fill} in the #{mode} theme; it must read --color-violet-ink"
    end
  end

  test "there is no bg-violet-ink or border-violet-ink to reach for" do
    %w[bg border ring].each do |util|
      refute_match(/\.#{util}-violet-ink[{\\:]/, compiled_css,
                   "#{util}-violet-ink compiled; the ink belongs in textColor only, so a fill cannot drift off-brand")
    end
  end

  # ── the bar ────────────────────────────────────────────────────────────────

  test "text-violet-ink clears AA on every theme surface and violet tint in both themes" do
    THEME_SELECTORS.each_key do |mode|
      ink, measured = ink_ratios(mode)
      measured.each do |ground, (ratio, bg)|
        assert_operator ratio, :>=, AA_TEXT,
                        "text-violet-ink (#{ink}) on the #{mode} #{ground} (#{bg}) is " \
                        "#{format('%.2f', ratio)}:1; AA needs 4.5:1 for small text"
      end
    end
  end

  # ── controls: each half of the fix has to be load-bearing ──────────────────

  test "control: the brand violet as text fails AA on the card in both themes" do
    expected = { light: 3.10, dark: 3.60 }
    expected.each do |mode, measured_when_built|
      ink, ratios = ink_ratios(mode, selector: ".text-violet")
      assert_equal "#8E82FE", ink.upcase, "the control must measure the bare brand violet"
      ratio, = ratios.fetch("card")
      assert_operator ratio, :<, AA_TEXT,
                      "the brand violet on the #{mode} card is #{format('%.2f', ratio)}:1, which would make the ink pointless"
      assert_in_delta measured_when_built, ratio, 0.01,
                      "the #{mode} card measured #{measured_when_built}:1 when this was built"
    end
  end

  test "control: neither ink can serve the other theme" do
    { dark: "#5B50CE", light: "#C5C0FE" }.each do |mode, wrong_ink|
      _, ratios = ink_ratios(mode, overrides: { "--color-violet-ink" => wrong_ink })
      ratio, = ratios.fetch("card")
      assert_operator ratio, :<, AA_TEXT,
                      "#{wrong_ink} on the #{mode} card is #{format('%.2f', ratio)}:1; the ink must stay per theme, " \
                      "not a flip of the other one"
    end
  end

  # ── no view may reach for the fill as small text ───────────────────────────

  test "bare text-violet appears only where large type or a graphical dot needs the fill" do
    found = Hash.new(0)
    SCANNED.each do |root|
      Dir[root.join("**/*.{erb,rb}")].each do |path|
        hits = File.read(path).scan(/text-violet(?![\w-])/).size
        found[path.delete_prefix("#{Rails.root}/")] += hits if hits.positive?
      end
    end

    unexpected = found.reject { |path, _| BARE_TEXT_VIOLET_ALLOWED.key?(path) }
    assert_empty unexpected,
                 "these paint text with the brand FILL, which is 3.10:1 on the light card. " \
                 "Use text-violet-ink, or add the file to BARE_TEXT_VIOLET_ALLOWED with the reason it is large type."

    BARE_TEXT_VIOLET_ALLOWED.each do |path, count|
      assert_equal count, found[path],
                   "#{path} has #{found[path]} bare text-violet uses, not #{count}. If a NEW one is small text it owes " \
                   "text-violet-ink; if it is genuinely large type, bump the count here and say why."
    end
  end
end
