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
    # violet does ON THE CARD: 3.10:1 light (#ffffff), 3.60:1 dark (#3C3853).
    #
    # ON THE CARD IS THE WHOLE EXEMPTION, and an earlier revision of this list
    # got it wrong. It also exempted seven lines in pages/turf_totals_v1 and
    # pages/turf_monster_v1 under the same 3.10:1 figure — but every one of them
    # sits inside a `bg-surface-alt` container, where the brand violet measures
    # **2.79:1** light (#F1F3F4), UNDER the 3:1 large-text floor. A large-text
    # exemption is a claim about a SURFACE, not about a font size, so citing the
    # card for text that is not on the card exempts a genuine failure. Worse, the
    # exemption is a COUNT: pinning those seven here would have made the next
    # person who fixed one red this test and told them to restore the number.
    # They read `text-violet-ink` now (5.42:1 light, 10.64:1 dark on that
    # surface) and are gone from this list.
    #
    # The two that remain are `text-2xl font-extrabold` (24px bold) directly on
    # `.card`, which compiles to var(--color-surface). Verified, not assumed.
    # EACH ENTRY CARRIES ITS KIND, because the two kinds are exempt for
    # different reasons and only one of them is a claim about a surface.
    "app/views/admin/scoring/index.html.erb" => { count: 1, kind: :large_text },
    "app/views/games/index.html.erb" => { count: 1, kind: :large_text },
    # Not text: a 4x4 status dot whose label is sr-only. It is a graphical
    # object under WCAG 1.4.11 (3:1), and it already picks its shade per theme
    # on purpose — violet-600 on light surfaces, the base violet on dark. Its
    # surface is unresolvable from here BY CONSTRUCTION: it is a partial, so the
    # background comes from whichever view renders it. What makes it safe is the
    # `dark:` scoping, and that is what gets asserted.
    "app/views/admin/pending_transactions/_signer_roster.html.erb" => { count: 2, kind: :graphical }
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


  # ── which SURFACE a line actually sits on ──────────────────────────────────
  #
  # The allow-list's exemption is a claim about a surface, not about a font
  # size: WCAG large type clears at 3:1, and whether the brand violet reaches
  # 3:1 depends entirely on what is behind it. It does on the card (3.10:1
  # light) and does NOT on `bg-surface-alt` (2.79:1 light). So the exemption is
  # MEASURED here rather than asserted in a comment, because a comment is
  # exactly how seven failing lines were once exempted by citing a surface they
  # were not on.
  #
  # The walk is adapted from error_text_contrast_test's `element_chains`: ERB
  # tags and HTML comments are blanked with their newlines preserved, so line
  # numbers still map, and the remaining tags are walked with a stack.
  VOID_TAGS = %w[area base br col embed hr img input link meta source track wbr].freeze

  # Longest first — `bg-surface-alt` contains `bg-surface`.
  SURFACE_CLASSES = {
    "bg-surface-alt" => :"surface-alt", "bg-surface" => :card, "bg-page" => :page,
    "bg-inset" => :inset, "card" => :card
  }.freeze

  def element_chains(path)
    @element_chains ||= {}
    @element_chains[path] ||= begin
      src = File.read(path).gsub(/<%.*?%>|<!--.*?-->/m) { |m| "\n" * m.count("\n") }
      stack = []
      chains = Hash.new { |h, k| h[k] = [] }
      src.scan(%r{<(/?)([a-zA-Z][\w-]*)([^>]*?)(/?)>}) do
        closing, tag, attrs, selfclose = Regexp.last_match.captures
        line = src[0...Regexp.last_match.begin(0)].count("\n") + 1
        tag = tag.downcase
        if closing == "/"
          idx = stack.rindex { |candidate, _| candidate == tag }
          stack.slice!(idx..) if idx
        else
          classes = attrs.scan(/(?::class|class)="([^"]*)"/).flatten.join(" ")
          chains[line] << (stack.map(&:last) + [ classes ])
          stack << [ tag, classes ] unless selfclose == "/" || VOID_TAGS.include?(tag)
        end
      end
      chains
    end
  end

  # The INNERMOST enclosing surface. `nil` when nothing in the chain names one —
  # reported rather than defaulted, because guessing the card is the mistake
  # this method exists to stop.
  def enclosing_surface(path, line, token: "text-violet")
    candidates = element_chains(path)[line]
    chain = candidates.find { |c| c.last.to_s.include?(token) } || candidates.first || []

    found = nil
    chain.each do |classes|
      classes.to_s.split(/\s+/).each do |klass|
        bare = klass.sub(/\A.*:/, "")
        name = SURFACE_CLASSES.find { |css, _| bare == css }&.last
        found = name if name
      end
    end
    found
  end

  def bare_violet_lines(path)
    File.readlines(Rails.root.join(path)).each_with_index.filter_map do |text, i|
      i + 1 if text.match?(/text-violet(?![\w-])/)
    end
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

    BARE_TEXT_VIOLET_ALLOWED.each do |path, rule|
      assert_equal rule[:count], found[path],
                   "#{path} has #{found[path]} bare text-violet uses, not #{rule[:count]}. If a NEW one is small text it owes " \
                   "text-violet-ink; if it is genuinely large type, bump the count here and say why."
    end
  end

  # THE EXEMPTION IS ABOUT THE SURFACE. Large type buys 3:1, not a pass — so
  # every allow-listed line has to sit somewhere the brand violet reaches 3:1.
  # Without this, the list is prose: seven lines were once exempted here citing
  # the card's 3.10:1 while sitting in bg-surface-alt at 2.79:1, and because the
  # exemption is a COUNT, fixing one of them would have reddened this suite and
  # told the fixer to restore the number.
  test "every allow-listed bare text-violet sits on a surface where the fill clears 3:1" do
    large_text = 3.0

    BARE_TEXT_VIOLET_ALLOWED.select { |_, rule| rule[:kind] == :large_text }.each_key do |path|
      lines = bare_violet_lines(path)
      assert_equal BARE_TEXT_VIOLET_ALLOWED[path][:count], lines.length,
                   "#{path}: the line scan and the count must agree"

      lines.each do |line|
        surface = enclosing_surface(path, line)
        assert surface, "#{path}:#{line} names no enclosing surface — resolve it rather than assuming the card"

        %i[light dark].each do |mode|
          fill = opaque(last_rule_for(".text-violet", "color")["color"], tokens(mode))
          ground = grounds(mode).fetch(surface.to_s)
          ratio = contrast(fill, ground)

          assert_operator ratio, :>=, large_text,
                          "#{path}:#{line} paints the brand fill on #{surface} (#{ground}) in the #{mode} theme, " \
                          "where it is #{ratio.round(2)}:1 — under the #{large_text}:1 WCAG large-text floor. " \
                          "Large type does not exempt a surface the fill cannot clear; use text-violet-ink."
        end
      end
    end
  end

  # The OTHER kind. A graphical exemption is not a claim about a surface — it is
  # a claim that the fill only ever paints where the theme can carry it. That is
  # true here only because every use is `dark:`-scoped, and on the dark theme the
  # brand clears 3:1 on all four surfaces. Assert BOTH halves: drop the `dark:`
  # and this reds, which is the real failure mode (a light-theme dot at 2.79:1).
  test "a graphical bare text-violet is dark-scoped, and the fill clears 3:1 there" do
    BARE_TEXT_VIOLET_ALLOWED.select { |_, rule| rule[:kind] == :graphical }.each_key do |path|
      File.readlines(Rails.root.join(path)).each_with_index do |text, i|
        text.scan(/(\S*)text-violet(?![\w-])/) do |(prefix)|
          assert_includes prefix, "dark:",
                          "#{path}:#{i + 1} paints the brand fill unscoped — a graphical exemption only holds " \
                          "where the theme can carry it, and the light theme cannot (2.79:1 on bg-surface-alt)"
        end
      end
    end

    fill = opaque(last_rule_for(".text-violet", "color")["color"], tokens(:dark))
    SURFACES.each_key do |name|
      assert_operator contrast(fill, grounds(:dark).fetch(name.to_s)), :>=, 3.0,
                      "the dark #{name} no longer carries the brand fill at 3:1 — the graphical exemption is void"
    end
  end

  # The control for the walk itself. A resolver that answered `card` for
  # everything would pass the test above no matter what shipped, so prove it
  # reads a real bg-surface-alt out of the file the finding came from.
  test "control: the ancestor walk really finds bg-surface-alt" do
    path = "app/views/pages/turf_totals_v1.html.erb"
    resolved = File.readlines(Rails.root.join(path)).each_with_index.filter_map do |text, i|
      enclosing_surface(path, i + 1, token: "text-violet-ink") if text.match?(/text-violet-ink/)
    end

    assert_includes resolved, :"surface-alt",
                    "the walk found #{resolved.tally.inspect} — if it can no longer see bg-surface-alt, " \
                    "the guard above is measuring the wrong ground for every line"
  end
end
