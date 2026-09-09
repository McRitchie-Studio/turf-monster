require "test_helper"

# Component tier for the modal/sign-in error-text legibility guard
# (task: error-text-fails-light-mode).
#
# THE BUG. Every error sentence on the wallet-setup and sign-in surfaces was
# painted with a static Tailwind red. The modal card is `bg-surface`, which
# resolves to PURE WHITE (#ffffff) in light mode, and no static red clears WCAG
# AA (4.5:1 for small text) there. Measured against this app's own resolved
# theme vars: text-red-400 is 2.89:1 on the light card and 3.86:1 on the dark
# card, so it failed BOTH; text-red-300 is 1.92:1 light. That is the sentence a
# user reads at the worst moment of a real-money sign-in.
#
# THE FIX. `text-danger-ink` — studio-engine's per-theme derived danger red
# (ThemeResolver#contrast_ink), which blends from the operator's brand danger
# colour only as far as AA demands and clears 4.5:1 on every THEME SURFACE.
#
# WHY THIS TEST MEASURES INSTEAD OF GREPPING. "assert the class is not
# text-red-400" passes the day someone writes text-rose-300, or an inline
# `style="color:#f87171"` — both of which this codebase actually contained. So
# nothing here reads a class NAME as evidence. Every text colour in scope is
# resolved through the COMPILED stylesheet (app/assets/builds/tailwind.css) and
# its var chain to a real sRGB colour; the ones that come out RED are measured
# against the resolved theme surfaces. A new light red is resolved and fails
# exactly like the old one.
#
# TAILWIND v4: the compiled palette is oklch(), not hex — `.text-red-400`
# compiles to `color:var(--color-red-400)` and that var is
# `oklch(70.4% .191 22.216)`. Resolution therefore goes through oklch -> sRGB;
# `test "oklch resolution is real"` pins it so an unresolved colour cannot
# silently skip the measurement.
#
# CI has the stylesheet: .github/workflows/ci.yml runs `bin/rails
# tailwindcss:build` before the suite, for this class of test.
class ModalErrorTextContrastTest < ActiveSupport::TestCase
  # The wallet-setup + sign-in surface: everything mounted in the modal host
  # (layouts/application renders "studio/modals/host"), plus the /signin card.
  SCOPE = (
    Dir[Rails.root.join("app/views/modals/**/*.html.erb")] +
    [ Rails.root.join("app/views/shared/_auth_card.html.erb").to_s ]
  ).sort.freeze

  COMPILED_CSS = Rails.root.join("app/assets/builds/tailwind.css").freeze
  AA_SMALL_TEXT = 4.5

  # ── colour space ──────────────────────────────────────────────────────────

  # Linear-light sRGB triple, the form both luminance and hex need.
  def srgb_linear(color)
    case color
    when /\A#(\h{6})\z/
      Regexp.last_match(1).scan(/../).map { |c| gamma_expand(c.to_i(16) / 255.0) }
    when /\A#(\h{3})\z/
      Regexp.last_match(1).chars.map { |c| gamma_expand((c * 2).to_i(16) / 255.0) }
    when /\Aoklch\(\s*([\d.]+)%?\s+([\d.]+)\s+([\d.]+)/
      oklch_linear(Regexp.last_match(1).to_f, Regexp.last_match(2).to_f, Regexp.last_match(3).to_f)
    end
  end

  def gamma_expand(v) = v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055)**2.4
  def gamma_compress(v) = v <= 0.0031308 ? 12.92 * v : 1.055 * (v**(1 / 2.4)) - 0.055

  # Bjorn Ottosson's oklab matrices. `l` arrives as a percentage (Tailwind v4
  # writes `70.4%`), so it is scaled back to the 0..1 the transform expects.
  def oklch_linear(l_pct, chroma, hue_deg)
    l = l_pct > 1.0 ? l_pct / 100.0 : l_pct
    h = hue_deg * Math::PI / 180.0
    a = chroma * Math.cos(h)
    b = chroma * Math.sin(h)
    lms = [ l + 0.3963377774 * a + 0.2158037573 * b,
            l - 0.1055613458 * a - 0.0638541728 * b,
            l - 0.0894841775 * a - 1.2914855480 * b ].map { |v| v**3 }
    ll, mm, ss = lms
    [ 4.0767416621 * ll - 3.3077115913 * mm + 0.2309699292 * ss,
      -1.2684380046 * ll + 2.6097574011 * mm - 0.3413193965 * ss,
      -0.0041960863 * ll - 0.7034186147 * mm + 1.7076147010 * ss ].map { |v| v.clamp(0.0, 1.0) }
  end

  def to_hex(color)
    lin = srgb_linear(color)
    return nil if lin.nil?

    "#" + lin.map { |v| format("%02x", (gamma_compress(v) * 255).round.clamp(0, 255)) }.join
  end

  def relative_luminance(color)
    r, g, b = srgb_linear(color)
    0.2126 * r + 0.7152 * g + 0.0722 * b
  end

  def contrast(fg, bg)
    a = relative_luminance(fg)
    b = relative_luminance(bg)
    ([ a, b ].max + 0.05) / ([ a, b ].min + 0.05)
  end

  # Is this a RED text colour? Asked of the resolved colour, never of the class
  # name — that is the whole point. Hue near 0 with real chroma; greys, greens
  # and the theme's quiet inks fall out on their own.
  def red_family?(color)
    r, g, b = srgb_linear(color).map { |v| gamma_compress(v) }
    max = [ r, g, b ].max
    min = [ r, g, b ].min
    return false if max - min < 0.12 # effectively grey

    span = max - min
    sector = if max == r
               ((g - b) / span) % 6
    elsif max == g
               (b - r) / span + 2
    else
               (r - g) / span + 4
    end
    hue = 60 * sector
    hue <= 35 || hue >= 330
  end

  # ── the two schemes, resolved exactly as production resolves them ─────────

  def theme_css = @theme_css ||= Studio::ThemeResolver.new(Studio.theme_config).to_css

  def theme_vars(scheme)
    block = scheme == :dark ? theme_css[/:root,\s*\.dark\s*\{(.*?)\n\}/m, 1]
                            : theme_css[/html:not\(\.dark\)\s*\{(.*?)\n\}/m, 1]
    block.to_s.scan(/(--[\w-]+):\s*([^;]+);/).to_h { |k, v| [ k, v.strip ] }
  end

  def compiled_css = @compiled_css ||= COMPILED_CSS.read

  # The static Tailwind palette (--color-red-400 and friends) lives in the
  # compiled stylesheet; the theme roles live in the runtime theme block. A var
  # is looked up in the theme first, because the theme is what overrides.
  def palette_vars
    @palette_vars ||= compiled_css.scan(/(--color-[\w-]+):\s*([^;}]+)[;}]/)
                                  .to_h { |k, v| [ k, v.strip ] }
  end

  # Follow `var(--a)` -> `var(--b)` -> a literal colour, in one scheme.
  def resolve(value, scheme, depth = 0)
    return nil if value.nil? || depth > 6

    value = value.strip
    if (name = value[/\Avar\(\s*(--[\w-]+)/, 1])
      return resolve(theme_vars(scheme)[name] || palette_vars[name], scheme, depth + 1)
    end
    srgb_linear(value) ? value : nil
  end

  # A utility class -> the colour it paints, per scheme. Read from the COMPILED
  # rule, so the mapping is the one the browser actually gets.
  def class_color(klass, scheme)
    decl = compiled_css[/(?<![\w.-])\.#{Regexp.escape(klass)}\s*\{[^}]*?color:\s*([^;}]+)[;}]/, 1]
    resolve(decl, scheme)
  end

  # ── what is on the surface ────────────────────────────────────────────────

  # Every element in scope that paints text, as [file, line, source, klass].
  # Covers `class="..."`, `:class="a ? 'x' : 'y'"` (both branches — Alpine picks
  # either at runtime) and inline `style="color:..."`.
  def text_color_sites
    SCOPE.flat_map do |path|
      rel = Pathname(path).relative_path_from(Rails.root).to_s
      File.readlines(path).each_with_index.flat_map do |line, i|
        sites = []
        line.scan(/style="[^"]*?color:\s*(#\h{3,6})/) { sites << [ "inline style", Regexp.last_match(1) ] }
        line.scan(/(?::class|class)="([^"]*)"/) do
          Regexp.last_match(1).scan(/[\w-]*text-[\w.\/-]+/) { |k| sites << [ k, k ] }
        end
        sites.map { |source, token| [ rel, i + 1, source, token ] }
      end
    end
  end

  # Resolved red text in scope: [file, line, source, hex] per scheme.
  def red_text_sites(scheme)
    text_color_sites.filter_map do |rel, line, source, token|
      color = token.start_with?("#") ? token : class_color(token, scheme)
      next if color.nil?
      next unless red_family?(color)

      [ rel, line, source, to_hex(color) ]
    end
  end

  # Every surface a modal's text can land on, resolved per scheme. This mirrors
  # ThemeResolver's own contract for the ink ("clears its target on ALL of
  # them"), so the guard asks for exactly what the token promises.
  def surfaces(scheme)
    vars = theme_vars(scheme)
    %w[--color-surface --color-page --color-surface-alt --color-inset]
      .to_h { |name| [ name, resolve(vars[name], scheme) ] }
      .compact
  end

  # ── the guard ─────────────────────────────────────────────────────────────

  test "the compiled stylesheet is present, so the measurements below are real" do
    assert COMPILED_CSS.exist?,
           "#{COMPILED_CSS} is missing — run `bin/rails tailwindcss:build`. Without it every " \
           "resolve() returns nil and this file would pass by measuring NOTHING."
    assert_operator text_color_sites.length, :>, 50,
                    "found only #{text_color_sites.length} text-colour sites across #{SCOPE.length} " \
                    "files — the scanner is not reading the surface it claims to."
  end

  test "every red error sentence in the modal and sign-in surfaces clears AA in both schemes" do
    failures = []

    %i[light dark].each do |scheme|
      sites = red_text_sites(scheme)
      surfaces(scheme).each do |surface_name, surface|
        sites.each do |rel, line, source, hex|
          ratio = contrast(hex, surface)
          next if ratio >= AA_SMALL_TEXT

          failures << "#{rel}:#{line} (#{source} -> #{hex}) is #{format('%.2f', ratio)}:1 on " \
                      "#{scheme} #{surface_name} #{to_hex(surface)} — AA needs #{AA_SMALL_TEXT}:1"
        end
      end
    end

    assert_empty failures, "red text below WCAG AA on a theme surface:\n  " + failures.join("\n  ")
  end

  test "the guarded surfaces actually contain red error text, so the assertion is not vacuous" do
    %i[light dark].each do |scheme|
      sites = red_text_sites(scheme)
      assert_operator sites.length, :>=, 10,
                      "only #{sites.length} red text sites resolved in #{scheme} — the sweep found 12. " \
                      "If they were repainted non-red the guard above is measuring nothing."
      assert(sites.any? { |rel, _, _, _| rel.include?("_wallet_setup") },
             "the wallet-setup error paragraph — the reported defect — is not among the measured sites")
      assert(sites.any? { |rel, _, _, _| rel.include?("_auth_card") },
             "the sign-in card error paragraph is not among the measured sites")
    end
  end

  # ── controls: prove the machinery bites ───────────────────────────────────

  test "oklch resolution is real, so a v4 palette colour cannot skip the measurement" do
    assert_equal "#ff6467", to_hex(resolve("var(--color-red-400)", :light)),
                 "Tailwind v4 writes the palette as oklch(); if this stops resolving, every " \
                 "static red would come back nil and be silently skipped rather than measured."
  end

  test "the old class would fail this guard — on the light card, which is the reported defect" do
    red400 = resolve("var(--color-red-400)", :light)
    card   = surfaces(:light)["--color-surface"]

    assert_equal "#ffffff", to_hex(card), "the light modal card is white; that is why red-400 fails on it"
    assert red_family?(red400), "red-400 must be detected as red text, or the guard would skip it"
    assert_operator contrast(red400, card), :<, AA_SMALL_TEXT,
                    "text-red-400 measures #{format('%.2f', contrast(red400, card))}:1 on the white card. " \
                    "If this ever passes, the bug is gone and this guard is unnecessary."
  end

  test "swapping in a DIFFERENT light red is caught too, which a class-name assertion would miss" do
    card = surfaces(:light)["--color-surface"]

    { "--color-red-300" => "another Tailwind red",
      "--color-rose-300" => "a different red-ish hue",
      "--color-orange-300" => "the neighbouring family" }.each do |var, why|
      color = resolve("var(#{var})", :light)
      next if color.nil? # palette shade not compiled into this build

      assert red_family?(color), "#{var} (#{why}) must be detected as red text by hue, not by name"
      assert_operator contrast(color, card), :<, AA_SMALL_TEXT,
                      "#{var} is #{format('%.2f', contrast(color, card))}:1 on the white card — the " \
                      "guard must reject it, which is why nothing here matches on the string 'red-400'."
    end
  end

  test "an inline hex is measured too, since two modals shipped colour that way" do
    card = surfaces(:light)["--color-surface"]

    assert red_family?("#f87171")
    assert_operator contrast("#f87171", card), :<, AA_SMALL_TEXT,
                    "the inline style=\"color:#f87171\" both newsletter modals carried is " \
                    "#{format('%.2f', contrast('#f87171', card))}:1 on the white card"
  end

  test "the theme ink is not simply dark everywhere — it is derived per scheme" do
    light_ink = resolve("var(--color-danger-ink)", :light)
    dark_ink  = resolve("var(--color-danger-ink)", :dark)

    refute_equal to_hex(light_ink), to_hex(dark_ink),
                 "danger-ink must differ by scheme; one static value cannot clear AA on both cards"
    assert_operator contrast(light_ink, surfaces(:light)["--color-surface"]), :>=, AA_SMALL_TEXT
    assert_operator contrast(dark_ink, surfaces(:dark)["--color-surface"]), :>=, AA_SMALL_TEXT
    assert_operator contrast(light_ink, surfaces(:dark)["--color-surface"]), :<, AA_SMALL_TEXT,
                    "the LIGHT ink on the DARK card must fail — proving the two are not interchangeable " \
                    "and that the per-scheme var, not a hardcoded hex, is what makes both pass."
  end
end
