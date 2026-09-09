require "test_helper"

# Component tier for the USER-FACING error-text legibility guard
# (tasks: error-text-fails-light-mode, then quest-newsletter-hardcodes-red).
#
# THE BUG. Error sentences were painted with a static Tailwind red. The card
# they sit on is `bg-surface`, which resolves to PURE WHITE (#ffffff) in light
# mode, and no static red clears WCAG AA (4.5:1 for small text) there. Measured
# against this app's own resolved theme vars: text-red-400 is 2.89:1 on the
# light card, the inline `style="color:#f87171"` two newsletters carried is
# 2.77:1, and text-rose-300 is 1.92:1. That is the sentence a user reads at the
# worst moment of a real-money flow.
#
# THE FIX. `text-danger-ink` — studio-engine's per-theme derived danger red
# (ThemeResolver#contrast_ink), which blends from the operator's brand danger
# colour only as far as AA demands and clears 4.5:1 on every THEME SURFACE.
#
# NOTE FOR THE NEXT PERSON: the engine registers `danger-ink` under `textColor`
# ONLY (studio-engine tailwind/studio.tailwind.config.js) — deliberately, since
# a fill may be vivid but text may not. `borderColor` offers only `subtle` and
# `strong`. So `border-danger` and `border-danger-ink` are PHANTOM classes here:
# they compile to nothing and paint nothing. An error panel gets its affordance
# from the ink plus the copy, on a theme surface — not from a danger border.
# `test "a colour class that compiles to nothing is a defect"` enforces that.
#
# WHY THIS TEST MEASURES INSTEAD OF GREPPING. "assert the class is not
# text-red-400" passes the day someone writes text-rose-300, or an inline
# `style="color:#f87171"` — both of which this codebase actually contained. So
# nothing here reads a class NAME as evidence. Every text colour in scope is
# resolved through the COMPILED stylesheet (app/assets/builds/tailwind.css) and
# its var chain to a real sRGB colour; the ones that come out RED are measured
# against the backdrop they actually sit on. A new light red fails exactly like
# the old one, whatever it is called.
#
# TAILWIND v4: the compiled palette is oklch(), not hex — `.text-red-400`
# compiles to `color:var(--color-red-400)` and that var is
# `oklch(70.4% .191 22.216)`. Resolution therefore goes through oklch -> sRGB;
# `test "oklch resolution is real"` pins it so an unresolved colour cannot
# silently skip the measurement.
#
# CI has the stylesheet: .github/workflows/ci.yml runs `bin/rails
# tailwindcss:build` before the suite, for this class of test.
#
# ── WHAT THIS GUARD COVERS, AND WHY THAT LINE ─────────────────────────────────
#
# The scope was widened deliberately, in two lanes, rather than by adding
# one-off assertions per bug or by pointing it at the whole view tree.
#
#   LANE A — SURFACES (file-scoped). Every text colour in these files is
#   measured. It is the modal/sign-in surface plus the four user-facing error
#   surfaces triaged in quest-newsletter-hardcodes-red. Each was confirmed
#   user-reachable by READING ITS CONTROLLER, not by guessing.
#
#   LANE B — ERROR SENTENCES (behavioural, self-extending). Any element
#   ANYWHERE under app/views (except app/views/admin) bound to an error-ish
#   Alpine expression is measured, whatever file it lives in. This is what
#   catches the NEXT error paragraph without anyone remembering to widen a list.
#
# HOW THE SCOPE WAS SWEPT. By HUE, not by colour-family name: every text
# colour under app/views (4477 sites: `class`, `:class` both ternary branches,
# and inline `style="color:"`) was resolved through the compiled stylesheet and
# classified by its resolved HSL hue, keeping everything at <=35deg or >=330deg.
# A `text-red-*` grep missed `text-rose-300` in wallet_exports TWICE; a hue
# sweep cannot miss it, and it is also what surfaced the FOURTH site
# (proof_of_reserves) beyond the three the ticket named. The sweep found 66
# red-hue text sites: 20 are the guarded `text-danger-ink` ones below, 26 are
# under app/views/admin, and 20 are non-admin sites that are not error
# sentences.
#
# DELIBERATELY OUT OF SCOPE — app/views/admin/** (26 sites) and the 20 non-admin
# static-red sites. They were read, not assumed: LIVE badges
# (live/index.html.erb, live/_game_tile.html.erb, contests/_live_game_chip),
# a "Cancelled" status chip on a bg-red-100 fill (contests/_contest_header),
# debit-amount indicators (wallets/show.html.erb, transaction_logs/*), the
# theme's own `text-warning` role (contract/*, schema/index), an inline hex in
# an EMAIL template that gets no theme vars at all and so MUST stay literal
# (user_mailer/wallet_export.html.erb), and admin form-error boxes
# (contests/new|edit.html.erb, both behind `require_admin` AND already sitting
# on a dark bg-red-900/50 tint where the red reads fine). They are
# operator-facing, or not error sentences, or both. Widening to them would mean
# either repainting decorative reds or bumping a floor to hide them; both are
# worse than saying plainly that this guard is about error sentences a user
# reads.
#
# NOT GUARDED, KNOWN: variant-prefixed colours (`dark:text-amber-400/90`) are
# skipped rather than measured, because measuring a dark-variant class against
# the light surfaces would be wrong. `assert_no_unmeasured_variant_error_text`
# keeps that honest by failing if a GUARDED error sentence ever gets one.
class ErrorTextContrastTest < ActiveSupport::TestCase
  # ── LANE A: the surfaces whose every text colour is measured ───────────────
  SURFACE_SCOPE = (
    Dir[Rails.root.join("app/views/modals/**/*.html.erb")] +
    [
      "app/views/shared/_auth_card.html.erb",
      # quest-newsletter-hardcodes-red — user-facing error sentences:
      "app/views/contests/_quest_newsletter.html.erb",        # public contest page
      "app/views/contests/_turf_totals_leaderboard.html.erb", # contests#show + #live, both public
      "app/views/wallet_exports/show.html.erb",               # public magic-link self-custody export
      "app/views/proof_of_reserves/show.html.erb"             # public reserves page
    ].map { |rel| Rails.root.join(rel).to_s }
  ).sort.freeze

  # ── LANE B: error sentences anywhere but admin ────────────────────────────
  BEHAVIOURAL_SCOPE = Dir[Rails.root.join("app/views/**/*.html.erb")]
                        .reject { |p| p.include?("/app/views/admin/") }.sort.freeze

  # An element bound to one of these is an error sentence, wherever it lives.
  ERROR_BINDING = /x-(?:text|html)="[^"]*(?:[eE]rror|errMsg)/

  # The anti-vacuity floor, keyed to FILES rather than to a total count. A bare
  # ">= N red sites" floor is a number you raise whenever it fails, which is not
  # a floor; this one names the file that stopped being measured. Each entry is
  # "this file must resolve at least this many RED text sites in both schemes".
  GUARANTEED_RED_SITES = {
    "app/views/contests/_quest_newsletter.html.erb"        => 1,
    "app/views/contests/_turf_totals_leaderboard.html.erb" => 1,
    "app/views/wallet_exports/show.html.erb"               => 2,
    "app/views/proof_of_reserves/show.html.erb"            => 4,
    "app/views/modals/_wallet_setup.html.erb"              => 1,
    "app/views/modals/_auth.html.erb"                      => 3,
    "app/views/modals/_cdp_ramp.html.erb"                  => 3,
    "app/views/modals/_newsletter_subscribe.html.erb"      => 1,
    "app/views/modals/_unsubscribe_confirm.html.erb"       => 1,
    "app/views/modals/_wallet_changed.html.erb"            => 1,
    "app/views/modals/auth/_resend_footer.html.erb"        => 1,
    "app/views/shared/_auth_card.html.erb"                 => 1
  }.freeze

  COMPILED_CSS = Rails.root.join("app/assets/builds/tailwind.css").freeze
  AA_SMALL_TEXT = 4.5
  VOID_TAGS = %w[area base br col embed hr img input link meta param source track wbr].freeze

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

    lin_to_hex(lin)
  end

  def lin_to_hex(lin)
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

  # Paint a translucent colour over an opaque backdrop, in linear light. This is
  # what the browser does, and it is the only way to know what an error sentence
  # on a tinted panel actually contrasts against.
  def composite(tint, alpha, backdrop)
    t = srgb_linear(tint)
    b = srgb_linear(backdrop)
    lin_to_hex(t.each_with_index.map { |v, i| v * alpha + b[i] * (1 - alpha) })
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
    @theme_vars ||= {}
    @theme_vars[scheme] ||= begin
      block = scheme == :dark ? theme_css[/:root,\s*\.dark\s*\{(.*?)\n\}/m, 1]
                              : theme_css[/html:not\(\.dark\)\s*\{(.*?)\n\}/m, 1]
      block.to_s.scan(/(--[\w-]+):\s*([^;]+);/).to_h { |k, v| [ k, v.strip ] }
    end
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

  # Resolve a BACKGROUND value to [opaque colour, alpha]. Tailwind v4 emits an
  # alpha background two ways — `#rrggbbaa` and
  # `color-mix(in oklab, var(--c) N%, transparent)` — and both appear in the
  # same build, so both are read here.
  def resolve_bg(value, scheme, depth = 0)
    return nil if value.nil? || depth > 6

    value = value.strip
    if (name = value[/\Avar\(\s*(--[\w-]+)/, 1])
      return resolve_bg(theme_vars(scheme)[name] || palette_vars[name], scheme, depth + 1)
    end
    if (m = value.match(/\Acolor-mix\(\s*in\s+\w+\s*,\s*(.+?)\s+([\d.]+)%\s*,\s*transparent\s*\)\z/))
      inner = resolve_bg(m[1], scheme, depth + 1)
      return nil if inner.nil?

      return [ inner[0], inner[1] * (m[2].to_f / 100.0) ]
    end
    if (m = value.match(/\A#(\h{6})(\h{2})\z/))
      return [ "#" + m[1], m[2].to_i(16) / 255.0 ]
    end
    if value.match?(/\Argba?\(/)
      expanded = value.gsub(/var\(\s*(--[\w-]+)\s*\)/) do
        theme_vars(scheme)[Regexp.last_match(1)] || palette_vars[Regexp.last_match(1)] || ""
      end
      nums = expanded.scan(/[\d.]+%?/)
      return nil if nums.length < 3

      rgb = nums[0, 3].map { |n| n.to_f.clamp(0, 255) }
      alpha = nums[3] ? (nums[3].end_with?("%") ? nums[3].to_f / 100.0 : nums[3].to_f) : 1.0
      return [ "#" + rgb.map { |c| format("%02x", c.round) }.join, alpha.clamp(0.0, 1.0) ]
    end
    srgb_linear(value) ? [ value, 1.0 ] : nil
  end

  # A class name as it is written in the COMPILED stylesheet: `bg-red-500/10`
  # is the selector `.bg-red-500\/10`.
  def selector_pattern(klass, property)
    sel = "." + klass.gsub("/", "\\/")
    /(?<![\w.\\-])#{Regexp.escape(sel)}(?![\w\\\/-])\s*\{[^}]*?#{property}:\s*([^;}]+)[;}]/
  end

  def rule_exists?(klass)
    sel = "." + klass.gsub("/", "\\/")
    compiled_css.match?(/(?<![\w.\\-])#{Regexp.escape(sel)}(?![\w\\\/-])\s*[,{]/)
  end

  # A utility class -> the colour it paints, per scheme. Read from the COMPILED
  # rule, so the mapping is the one the browser actually gets. The LAST matching
  # declaration wins, as it does in the cascade.
  def class_color(klass, scheme)
    decl = compiled_css.scan(selector_pattern(klass, "color")).flatten.last
    resolve(decl, scheme)
  end

  def class_background(klass, scheme)
    decl = compiled_css.scan(selector_pattern(klass, "background(?:-color)?")).flatten.last
    resolve_bg(decl, scheme)
  end

  # ── what is on the surface ────────────────────────────────────────────────

  # The element on each line, with the class attributes of every element
  # ENCLOSING it. ERB tags and HTML comments are blanked (newlines preserved, so
  # line numbers still map) and the remaining tags are walked with a stack.
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
          idx = stack.rindex { |t, _| t == tag }
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

  # The backdrop an element actually sits on, per theme surface: each enclosing
  # background is painted over the surface in order, so a tint composites and an
  # opaque background replaces.
  def backdrops(path, line, token, scheme)
    candidates = element_chains(path)[line]
    chain = candidates.find { |c| c.last.to_s.include?(token) } || candidates.first || []

    surfaces(scheme).to_h do |sname, base|
      bg = base
      chain.each do |classes|
        classes.to_s.split(/\s+/).each do |k|
          next if k.include?(":") # variant-prefixed; not this scheme's business

          parsed = class_background(k, scheme)
          next if parsed.nil?

          color, alpha = parsed
          bg = alpha >= 0.999 ? color : composite(color, alpha, bg)
        end
      end
      [ sname, bg ]
    end
  end

  # Every element in a file that paints text, as [line, source, token]. Covers
  # `class="..."`, `:class="a ? 'x' : 'y'"` (both branches — Alpine picks either
  # at runtime) and inline `style="color:..."`.
  #
  # Scanned over the WHOLE FILE, not line by line, because this codebase writes
  # multi-line `:class="{ ... }"` object literals and a per-line scan requires
  # the closing quote on the same line — so it silently skipped every token in
  # them. proof_of_reserves' solvency banner (the "vault is short" colour) hid
  # in exactly such an attribute. Each token is attributed to the line its
  # ELEMENT opens on, which is the line `element_chains` keys on, so the
  # backdrop lookup still finds the right ancestors.
  def text_sites_in(path)
    @text_sites ||= {}
    @text_sites[path] ||= begin
      src = File.read(path)
      line_of = ->(offset) { src[0...offset].count("\n") + 1 }
      element_line = lambda do |offset|
        open_at = src[0...offset].rindex("<") || offset
        line_of.call(open_at)
      end

      sites = []
      src.to_enum(:scan, /style="[^"]*?color:\s*(#\h{3,8})/m).map { Regexp.last_match }.each do |m|
        sites << [ element_line.call(m.begin(0)), "inline style", m[1] ]
      end
      src.to_enum(:scan, /(?::class|class)="([^"]*)"/m).map { Regexp.last_match }.each do |m|
        line = element_line.call(m.begin(0))
        m[1].scan(%r{[\w:.-]*text-[\w./-]+}) { |k| sites << [ line, k, k ] }
      end
      sites
    end
  end

  # LANE A + LANE B, as [path, line, source, token].
  def guarded_sites
    @guarded_sites ||= begin
      a = SURFACE_SCOPE.flat_map { |p| text_sites_in(p).map { |l, s, t| [ p, l, s, t ] } }
      b = BEHAVIOURAL_SCOPE.flat_map do |p|
        error_lines = File.readlines(p).each_with_index.filter_map { |l, i| i + 1 if l.match?(ERROR_BINDING) }
        next [] if error_lines.empty?

        text_sites_in(p).select { |l, _, _| error_lines.include?(l) }.map { |l, s, t| [ p, l, s, t ] }
      end
      (a + b).uniq
    end
  end

  def rel(path) = Pathname(path).relative_path_from(Rails.root).to_s

  # Resolved RED text in scope, with the backdrop it truly sits on.
  def red_sites(scheme)
    guarded_sites.filter_map do |path, line, source, token|
      next if token.include?(":") && !token.start_with?("#") # variant-prefixed

      color = token.start_with?("#") ? token[0, 7] : class_color(token, scheme)
      next if color.nil?
      next unless red_family?(color)

      [ rel(path), line, source, to_hex(color), backdrops(path, line, token, scheme) ]
    end
  end

  # Every surface a guarded element's text can land on, resolved per scheme.
  # This mirrors ThemeResolver's own contract for the ink ("clears its target on
  # ALL of them"), so the guard asks for exactly what the token promises.
  def surfaces(scheme)
    @surfaces ||= {}
    @surfaces[scheme] ||= begin
      vars = theme_vars(scheme)
      %w[--color-surface --color-page --color-surface-alt --color-inset]
        .to_h { |name| [ name, resolve(vars[name], scheme) ] }
        .compact
    end
  end

  # ── the guard ─────────────────────────────────────────────────────────────

  test "the compiled stylesheet is present, so the measurements below are real" do
    assert COMPILED_CSS.exist?,
           "#{COMPILED_CSS} is missing — run `bin/rails tailwindcss:build`. Without it every " \
           "resolve() returns nil and this file would pass by measuring NOTHING."
    assert_operator guarded_sites.length, :>, 50,
                    "found only #{guarded_sites.length} text-colour sites across " \
                    "#{SURFACE_SCOPE.length} guarded files — the scanner is not reading the " \
                    "surface it claims to."
  end

  test "every red error sentence in scope clears AA on the backdrop it actually sits on" do
    failures = []
    measured = 0

    %i[light dark].each do |scheme|
      red_sites(scheme).each do |file, line, source, hex, backs|
        backs.each do |surface_name, backdrop|
          measured += 1
          ratio = contrast(hex, backdrop)
          next if ratio >= AA_SMALL_TEXT

          failures << "#{file}:#{line} (#{source} -> #{hex}) is #{format('%.2f', ratio)}:1 on " \
                      "#{scheme} #{surface_name} #{backdrop} — AA needs #{AA_SMALL_TEXT}:1"
        end
      end
    end

    # The anti-vacuity check lives HERE, on the assertion that would otherwise
    # pass by measuring an empty set. `assert_empty failures` is green when
    # nothing was measured at all, so it cannot be the only thing standing
    # between this file and a silent no-op.
    assert_operator measured, :>, 0,
                    "this assertion measured ZERO colour/backdrop pairs — it would have passed " \
                    "no matter what the views contain. Something upstream (the scope, the " \
                    "stylesheet, or the resolver) stopped producing sites."

    assert_empty failures, "red text below WCAG AA on the backdrop it sits on:\n  " + failures.join("\n  ")
  end

  test "each guarded file still contributes the red sites it is guarded for" do
    %i[light dark].each do |scheme|
      counts = red_sites(scheme).group_by { |file, _, _, _, _| file }.transform_values(&:length)

      GUARANTEED_RED_SITES.each do |file, minimum|
        actual = counts.fetch(file, 0)
        assert_operator actual, :>=, minimum,
                        "#{file} resolved #{actual} red text site(s) in #{scheme}, expected at " \
                        "least #{minimum}. Either its error text was repainted a non-red colour " \
                        "(in which case say so HERE, by editing GUARANTEED_RED_SITES, and explain " \
                        "why) or the guard quietly stopped seeing that file. This floor is keyed " \
                        "to files on purpose: a bare total is a number you raise whenever it fails."
      end
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
      "--color-rose-300" => "the family that was missed by two greps for text-red-*",
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
                    "the inline style=\"color:#f87171\" both newsletters carried is " \
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

  # ── controls for the backdrop model (the guard's second blind spot) ────────

  test "a tinted panel is composited, so danger-ink on bg-red-500/10 is NOT read as if on the card" do
    # This is the case that nearly shipped: text-danger-ink inside the
    # leaderboard's old `bg-red-500/10` box measures 4.50:1 against the DARK
    # card and passes, but 3.78:1 against the tint the user actually sees.
    dark_card = surfaces(:dark)["--color-surface"]
    ink       = resolve("var(--color-danger-ink)", :dark)
    red500    = resolve("var(--color-red-500)", :dark)
    tinted    = composite(red500, 0.10, dark_card)

    assert_operator contrast(ink, dark_card), :>=, AA_SMALL_TEXT,
                    "danger-ink clears AA on the bare dark card — which is exactly why measuring " \
                    "only the theme surfaces would have called the tinted panel fine."
    assert_operator contrast(ink, tinted), :<, AA_SMALL_TEXT,
                    "danger-ink on a 10% red tint over the dark card is " \
                    "#{format('%.2f', contrast(ink, tinted))}:1. If this ever passes, the tint is " \
                    "no longer a hazard and this control can go."
  end

  test "the ancestor scan finds a real enclosing background, and does not invent one" do
    # Pins the tag-stack walker against two files whose structure is known. The
    # walker is the only reason the composite above can be applied to the right
    # element, so drift in it has to be visible.
    leaderboard = Rails.root.join("app/views/contests/_turf_totals_leaderboard.html.erb").to_s
    line, = text_sites_in(leaderboard).find { |_, _, t| t == "text-danger-ink" }
    chain = element_chains(leaderboard)[line].first.join(" ")
    assert_includes chain, "bg-surface-alt",
                    "the error panel's own background must be seen by the ancestor scan"

    # wallet_exports has a bg-rose-500/10 warning banner AND a bg-emerald-500/10
    # success panel, neither of which encloses the error paragraph. A scan that
    # blamed the whole file would composite them and fail falsely.
    exports = Rails.root.join("app/views/wallet_exports/show.html.erb").to_s
    eline, = text_sites_in(exports).find { |_, _, t| t == "text-danger-ink" }
    echain = element_chains(exports)[eline].first.join(" ")
    refute_includes echain, "bg-rose-500/10",
                    "the export error paragraph sits on bg-surface, not inside the rose warning " \
                    "banner — the ancestor scan must not attribute a sibling's tint to it"
    assert_includes echain, "bg-surface",
                    "the export error paragraph's real enclosing surface must be found"
  end

  test "an alpha background parses from both forms Tailwind v4 emits" do
    mix = resolve_bg("color-mix(in oklab, var(--color-red-500) 10%, transparent)", :light)
    assert_in_delta 0.10, mix[1], 0.001, "the color-mix form must yield its alpha"
    assert_equal "#fb2c36", to_hex(mix[0])

    hex8 = resolve_bg("#3080ff1a", :light)
    assert_in_delta 0.102, hex8[1], 0.005, "the #rrggbbaa form must yield its alpha"
    assert_equal "#3080ff", hex8[0]
  end

  # ── control: a class that paints nothing ──────────────────────────────────

  test "a colour class that compiles to nothing is a defect, not something to skip" do
    # proof_of_reserves shipped `text-rose` — not a Tailwind class at all. It
    # resolved to nil, so a colour-measuring guard SKIPPED it, and the error
    # sentences on a public page were painted no colour whatsoever. The same
    # trap caught this task's own first fix, which reached for `border-danger`
    # (the engine registers danger only as textColor). A colour-shaped class
    # that the stylesheet does not define must fail loudly.
    families = (palette_vars.keys + theme_vars(:light).keys)
               .filter_map { |v| v[/\A--color-(.+)\z/, 1] }.uniq

    colourish = lambda do |suffix|
      base = suffix.split("/").first.to_s
      families.include?(base) || families.any? { |f| f.start_with?("#{base}-") }
    end

    phantoms = []
    (SURFACE_SCOPE + BEHAVIOURAL_SCOPE).uniq.each do |path|
      File.read(path).scan(/(?::class|class)="([^"]*)"/).flatten.each do |attr|
        attr.split(/\s+/).each do |raw|
          # Alpine writes classes inside ternaries and object literals
          # (`? 'border-primary bg-primary/10' :`), so a whitespace split leaves
          # quotes and punctuation glued to the name. Strip them, or the control
          # reports `bg-primary/10'` as a phantom when `bg-primary/10` is real.
          token = raw.gsub(/\A[^\w-]+|[^\w\/-]+\z/, "")
          next if token.empty?
          next if token.include?(":") # variant-prefixed selectors differ
          next unless (m = token.match(%r{\A(?:text|bg|border)-(.+)\z}))
          next unless colourish.call(m[1])
          next if rule_exists?(token)

          phantoms << "#{rel(path)}: #{token}"
        end
      end
    end

    assert_empty phantoms.uniq,
                 "these colour-shaped classes are not in the compiled stylesheet, so they paint " \
                 "NOTHING and a colour guard silently skips them:\n  " + phantoms.uniq.join("\n  ")
  end

  test "the guarded error sentences do not hide behind a variant-prefixed colour" do
    # Variant-prefixed colours (`dark:text-red-400`) are skipped by the
    # measurement, so an error sentence that used one would be unguarded. None
    # do; this fails if that changes.
    offenders = guarded_sites.select do |path, line, _, token|
      token.include?(":") && File.readlines(path)[line - 1].to_s.match?(ERROR_BINDING)
    end

    assert_empty offenders.map { |p, l, _, t| "#{rel(p)}:#{l} #{t}" },
                 "an error sentence is painted by a variant-prefixed class, which this guard " \
                 "does not measure — either give it an unconditional colour or teach the guard " \
                 "to resolve variants"
  end
end
