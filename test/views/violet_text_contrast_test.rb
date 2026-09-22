require "test_helper"
require "tmpdir"

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
#
# THE INLINE LANE IS NO LONGER VIOLET-ONLY. It used to filter to the violet
# pair, so it measured slates/show's Turf Score series and walked past its two
# siblings — `--fc-goals` at 1.96:1 on the light card and `--fc-dk-score` at
# 2.22:1 on the dark card, both recorded here as known-and-unfixed. Both are
# fixed now (task: fix-goals-and-dk-contrast), and the lane is PARAMETERISED
# over INLINE_SERIES below rather than copied per series: each entry names the
# page-local FILL token and the INK token that series must use as small text,
# and the scan filters to the colours those tokens resolve to.
#
# IT IS STILL LIST-FREE IN THE WAY THAT MATTERS. The registry names TOKENS, not
# files or lines, so planting `style="color: #B8B0FF"` on any scanned page is
# caught without widening anything. The per-series vacuity assertion is what
# keeps the loop honest: a guard that iterates a list proves nothing about
# member N by reddening member 1, so every series that paints text must be
# FOUND painting text, in both themes, or the suite says so.
#
# THE TAG-HELPER BLIND SPOT, NOW CLOSED. Rails tag-helper `style:` options are
# invisible to the walk above: the ERB is blanked before the tag scan, so
# `<%%= tag.span style: "color: ..." %>` never becomes an element. That is a
# hole in the property this file claims two paragraphs up — "planting
# `style="color: #B8B0FF"` on any scanned page is caught" is FALSE for the
# tag-helper form — so it gets a lane of its own (TAG_HELPER_* below) rather
# than a note.
#
# THE COUNT THIS PARAGRAPH USED TO CARRY WAS WRONG TWICE OVER, and it is worth
# recording why, because both errors are the kind a hand grep produces. It read
# "18 `style:` matches ... only FIVE declare a `color:` ... None resolves to a
# registered series colour, so a lane for them would assert nothing today".
# Re-derived 2026-09-22 (carl, reviewing PR 802; re-run by shannon with this
# file's own regex), the three numbers that matter are:
#
#   34  lines under app/views + app/helpers carry a `style:` OPTION — CONTEXT
#       ONLY, and the one number here that is not asserted: it moves whenever
#       anyone writes `style: "width: ..."`, so pinning it would red on changes
#       that have nothing to do with colour. Re-derive it with
#       `grep -rEn '(^|[^-\w:])style:[[:space:]]' app/views app/helpers
#       --include='*.erb' --include='*.rb' | wc -l` rather than trusting it.
#    9  of those also match this file's `color:` regex, /(?<![-\w])color\s*:/
#    7  of those nine yield a parseable CSS declaration — the two in
#       tokens/_paypal_sdk are JS object literals whose `color: 'blue'` is a
#       PayPal funding enum, not a colour, and `static_color` drops them
#    3  of those seven resolve to a REGISTERED SERIES COLOUR (in dark)
#
# The 9, the 7 and the 3 are each ASSERTED below. That is the point of the
# rewrite: the figure this paragraph carried before was a hand count, it was
# wrong, and nothing would have failed when it went wrong.
#
# So "none resolves to a registered series colour" was false, and it was
# falsifiable from INSIDE the old list of five: admin/seasons/index:77 writes
# `color: var(--color-primary-ink)`, which is exactly what `--fc-dk-score-ink`
# resolves to in dark (#81C784). The other two are admin/error_logs/index:38
# and :42, which the old count missed entirely. Each of the three numbers above
# is now asserted below rather than left as prose, because a hand count in a
# comment is precisely what rotted here.
#
# NO LIVE BUG EVER HID BEHIND IT. All three write `--color-primary-ink`, and
# the sibling guard test/views/primary_text_contrast_test.rb already proves
# that token clears AA on the card and the page in both themes. The lane below
# is therefore not a bug fix — it is the scanner catching up with a claim this
# file was already making.
class VioletTextContrastTest < ActiveSupport::TestCase
  AA_TEXT = 4.5
  COMPILED_CSS = Rails.root.join("app/assets/builds/tailwind.css").freeze
  SCANNED = [ Rails.root.join("app/views"), Rails.root.join("app/helpers") ].freeze
  THEME_SELECTORS = { dark: ":root,.dark", light: "html:not(.dark)" }.freeze
  SURFACES = {
    card: "--color-surface", page: "--color-page",
    "surface-alt": "--color-surface-alt", inset: "--color-inset"
  }.freeze
  # ── the brand series the inline lane measures ─────────────────────────────
  #
  # Each series is a colour that paints BOTH a graphic (a chart stroke, a
  # border-left, an accent-color — 3:1 under WCAG 1.4.11) and small TEXT, which
  # owes 4.5:1. `fill` is the token that must keep painting the graphics;
  # `ink` is the token the same series must use as text.
  #
  # BOTH are scanned, and that is the point: the fill so a site that reaches
  # back for it is caught, the ink so the fix stays measured instead of assumed.
  # The filter is by RESOLVED COLOUR, so a bare `#B8B0FF` is caught exactly like
  # the `var()` form.
  #
  # `paints_text: false` is a series that is graphics-only today. It is
  # registered anyway — its fill is scanned, so the day someone paints it as
  # text the lane measures it instead of discovering it a year later, which is
  # precisely how --fc-goals and --fc-dk-score went unwatched.
  INLINE_SERIES = {
    "Turf Score" => { fill: "--fc-mult", ink: "--fc-mult-ink", paints_text: true },
    "Goals" => { fill: "--fc-goals", ink: "--fc-goals-ink", paints_text: true },
    "DK Score" => { fill: "--fc-dk-score", ink: "--fc-dk-score-ink", paints_text: true },
    "DK Total" => { fill: "--fc-dk-total", ink: nil, paints_text: false }
  }.freeze

  # The page that declares the series tokens; the lane resolves them here once
  # and then hunts the resulting colours everywhere.
  SLATE_PAGE = "app/views/slates/show.html.erb"

  # Mailer templates render in their own layout with a fixed palette and never
  # see a theme surface. They are still SCANNED — a brand colour written into a
  # mailer is still a finding — but the page fallback does not apply to them, so
  # an unresolved ground fails loudly instead of being measured against a
  # surface the template never sits on.
  MAILER_VIEWS = %r{/app/views/[\w]*mailer/}

  # ── the tag-helper `style:` lane ───────────────────────────────────────────
  #
  # A Rails tag-helper option, `style: "color: ..."`, rather than an HTML
  # `style=` attribute. The `(?<!:)` is what keeps this off the attribute form
  # Alpine writes (`:style=`), which the element walk already covers.
  TAG_HELPER_STYLE = /(?<![-\w:])style:\s/

  # HOW BIG THE BLIND SPOT IS, ASSERTED. Every line under app/views +
  # app/helpers carrying a `style:` option whose text also matches this file's
  # `color:` regex, by file. The total is the NINE in the header; a hand count
  # said five, which is why it is a constant now and not a sentence. A new
  # tag-helper `color:` bumps a number here and fails, so the blind spot cannot
  # quietly grow — same doctrine as BARE_TEXT_VIOLET_ALLOWED above.
  TAG_HELPER_COLOR_SITES = {
    "app/views/admin/error_logs/index.html.erb" => 2,
    "app/views/admin/seasons/index.html.erb" => 3,
    "app/views/magic_links/confirm.html.erb" => 1,
    "app/views/shared/_impersonation_banner.html.erb" => 1,
    "app/views/tokens/_paypal_sdk.html.erb" => 2
  }.freeze

  # WHICH OF THEM PAINT A REGISTERED SERIES COLOUR, per theme, with the ground
  # the site actually sits on recorded beside it. LIGHT IS ASSERTED EMPTY and
  # that is a tripwire, not a vacuous pass: `--color-primary-ink` is
  # `var(--color-primary)` there (#2E7D32), which is nobody's series colour, so
  # a light-theme entry appearing here means a new site started painting one.
  #
  # The ground column is documentation, not the measurement. See the lane.
  TAG_HELPER_SERIES_SITES = {
    # #81C784 — what --fc-dk-score-ink resolves to in dark.
    dark: [
      # the class chips close their cards at :30, so these sit on the PAGE
      [ "app/views/admin/error_logs/index.html.erb", 38 ],
      [ "app/views/admin/error_logs/index.html.erb", 42 ],
      # inside `card p-6` at :51, so this one sits on the CARD
      [ "app/views/admin/seasons/index.html.erb", 77 ]
    ],
    light: []
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

  # CSS COMMENTS ARE STRIPPED FIRST, and that is load-bearing rather than
  # tidiness. A selector here is "everything since the last brace", so a `/* */`
  # comment sitting above a rule becomes part of its selector: `:root` parses as
  # `/*...*/:root`, matches nothing, and the whole block's custom properties
  # vanish from the guard's view. The sites that read them then resolve to
  # nothing and are SKIPPED rather than failed, so documenting a page's <style>
  # block would quietly switch this lane off for that page. Measured 2026-09-22:
  # adding the FILL-vs-INK comment to slates/show did exactly that, and the
  # per-series vacuity assertion is what caught it.
  def rules(css)
    css.gsub(%r{/\*.*?\*/}m, "").scan(/([^{}]+)\{([^{}]*)\}/).map { |sel, body| [ sel.gsub(/\s+/, ""), body ] }
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

  # ONE walk over the file produces both lanes, so they cannot disagree about
  # which element a line belongs to. `chains` answers "what encloses line N"
  # for the class lane; `styles` carries each inline `style` attribute TOGETHER
  # WITH the chain of the element that wrote it.
  #
  # Pairing the style with its own chain is the point. Resolving it by line
  # number instead means picking one of the several elements that can open on a
  # line, and the pick is a guess: on `<label ...>Base <span style="color:…">`
  # the styled element is the SECOND one. Today both answer `card`, so a
  # position-based pick looks correct — but two siblings on one line, the first
  # carrying `bg-inset` and the second the style, would measure the colour
  # against a surface it is not on. That is the same "guess the surface" error
  # the allow-list test below exists to prevent, so the inline lane does not
  # make it either.
  def parse_elements(path)
    @parse_elements ||= {}
    @parse_elements[path] ||= begin
      src = File.read(path).gsub(/<%.*?%>|<!--.*?-->/m) { |m| "\n" * m.count("\n") }
      stack = []
      chains = Hash.new { |h, k| h[k] = [] }
      styles = []
      src.scan(%r{<(/?)([a-zA-Z][\w-]*)([^>]*?)(/?)>}) do
        closing, tag, attrs, selfclose = Regexp.last_match.captures
        line = src[0...Regexp.last_match.begin(0)].count("\n") + 1
        tag = tag.downcase
        if closing == "/"
          idx = stack.rindex { |candidate, _| candidate == tag }
          stack.slice!(idx..) if idx
        else
          classes = attrs.scan(/(?::class|class)="([^"]*)"/).flatten.join(" ")
          chain = stack.map(&:last) + [ classes ]
          chains[line] << chain
          attrs.scan(/(?::style|style)="([^"]*)"/) { styles << [ line, Regexp.last_match(1), chain ] }
          stack << [ tag, classes ] unless selfclose == "/" || VOID_TAGS.include?(tag)
        end
      end
      { chains: chains, styles: styles }
    end
  end

  def element_chains(path) = parse_elements(path)[:chains]

  # The INNERMOST surface named anywhere in one element's ancestor chain. `nil`
  # when nothing names one — reported rather than defaulted, because guessing
  # the card is the mistake this method exists to stop.
  def surface_from_chain(chain)
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

  def enclosing_surface(path, line, token: "text-violet")
    candidates = element_chains(path)[line]
    surface_from_chain(candidates.find { |c| c.last.to_s.include?(token) } || candidates.first || [])
  end

  def bare_violet_lines(path)
    File.readlines(Rails.root.join(path)).each_with_index.filter_map do |text, i|
      i + 1 if text.match?(/text-violet(?![\w-])/)
    end
  end

  # Inline `color:` declarations are a separate lane from Tailwind classes.
  # That distinction matters: slates/show once painted five small labels with
  # `color: var(--fc-mult)`, so the class-only scan below never saw the same
  # brand violet it correctly rejected as `text-violet`.
  #
  # Reads `:style` as well as `style`, since Alpine writes the bound form.
  # Returns the element's own ancestor CHAIN with each declaration, so the
  # caller measures against the surface that element actually sits on.
  def inline_style_colors(path)
    parse_elements(path)[:styles].flat_map do |line, style, chain|
      style.scan(/(?<![-\w])color\s*:\s*([^;]+)/).map { |(value)| [ line, value.strip, chain ] }
    end
  end

  # The tag-helper twin of `inline_style_colors`, reading LINES rather than
  # elements because there is no element to read: the ERB these live in is
  # blanked before the tag scan, so nothing reaches `parse_elements`.
  #
  # Returns `[line, [expr, ...]]` per line that declares a `color:`. The value
  # pattern stops at a quote as well as a `;`, which is what keeps the PayPal
  # SDK's JS object literals (`style: { color: 'blue', height: 48 }`) out —
  # `color: 'blue'` is a PayPal funding enum, not a colour.
  #
  # THE BLANK REJECT IS NOT TIDINESS, it is what makes that exclusion real.
  # `\s*` backtracks to zero, so on `color: 'blue'` the `[^;"']+` happily
  # matches the SPACE before the quote and captures `" "`. Without the reject
  # those two lines yield an empty-string "declaration" and the parseable count
  # is 9 rather than 7 — measured, by the assertion below reddening when this
  # was first written with `unless exprs.empty?` alone.
  #
  # Both lines are still COUNTED by TAG_HELPER_COLOR_SITES: the blind spot is a
  # property of the text, not of what parses out of it.
  def tag_helper_style_colors(path)
    File.readlines(path).each_with_index.filter_map do |text, i|
      next unless text.match?(TAG_HELPER_STYLE)

      exprs = text.scan(/(?<![-\w])color\s*:\s*([^;"']+)/).flatten.map(&:strip).reject(&:empty?)
      [ i + 1, exprs ] unless exprs.empty?
    end
  end

  # Every line that COUNTS toward the blind spot: a `style:` option whose text
  # matches the `color:` regex, parseable or not.
  def tag_helper_color_lines(path)
    File.readlines(path).each_with_index.filter_map do |text, i|
      i + 1 if text.match?(TAG_HELPER_STYLE) && text.match?(/(?<![-\w])color\s*:/)
    end
  end

  # Resolve page-local custom properties with the same theme cascade used for
  # the compiled app tokens. This is what turns `var(--fc-mult)` into the real
  # colour the browser paints instead of treating the variable name as proof.
  def embedded_style_tokens(path, mode)
    css = File.read(path).scan(%r{<style[^>]*>(.*?)</style>}m).flatten.join("\n")
    rules(css).each_with_object({}) do |(selector, body), seen|
      selectors = selector.split(",")
      applies = selectors.include?(":root") ||
        (mode == :dark && selectors.any? { |s| [ ".dark", "html.dark" ].include?(s) }) ||
        (mode == :light && selectors.include?("html:not(.dark)"))
      seen.merge!(declarations(body).select { |name, _| name.start_with?("--") }) if applies
    end
  end

  # Resolve every STATIC colour — a literal hex, an rgb()/oklab() triple, or any
  # depth of `var()` chain — so a bare `#8E82FE` and a page-local alias like
  # `var(--fc-mult-ink)` take the same measured path. Anything a static scan
  # cannot resolve returns nil and is skipped rather than guessed at.
  #
  # Two kinds are out of reach, both deliberately: a colour ERB computes at
  # render time (`style="color: <%= palette[:accent] %>"`, which the tag walk
  # has already blanked to an unresolvable fragment by the time it arrives) and
  # one an Alpine expression computes at runtime. Neither has a value to
  # measure without rendering the page, so both fall out here. The sibling
  # guard, test/views/error_text_contrast_test.rb, stops at the same wall.
  def static_color(expr, toks)
    return if expr.include?("<%")

    value = expr.dup
    20.times do
      break unless value.include?("var(")

      unresolved = false
      value = value.gsub(/var\(\s*(--[\w-]+)\s*(?:,\s*([^()]*))?\)/) do
        replacement = toks[Regexp.last_match(1)] || Regexp.last_match(2)
        unresolved = true unless replacement
        replacement.to_s
      end
      return if unresolved
    end
    return if value.include?("var(")

    case value.strip
    when /\A#\h{3}(?:\h{3})?\z/
      hex(*rgb(value.strip))
    when %r{\Argb\(\s*(\d+)\s+(\d+)\s+(\d+)\s*(?:/\s*[\d.]+)?\s*\)\z}
      hex(Regexp.last_match(1).to_i, Regexp.last_match(2).to_i, Regexp.last_match(3).to_i)
    when %r{\Aoklab\(\s*([\d.]+)%\s+(-?[\d.]+)\s+(-?[\d.]+)\s*(?:/\s*[\d.]+)?\s*\)\z}
      oklab_to_hex(Regexp.last_match(1).to_f / 100.0, Regexp.last_match(2).to_f, Regexp.last_match(3).to_f)
    end
  end

  # An element whose own ancestor chain names no surface sits on the PAGE: the
  # app layout's <body> carries `bg-page`. That is ASSERTED by "the page
  # fallback is the layout's real background" below rather than assumed here.
  # Defaulting to the CARD would be the guess this walk exists to prevent — the
  # page is the one ground that is actually true for an element naming nothing,
  # and without it the two Save Formula buttons have no ground at all.
  #
  # MAILERS KEEP THE OLD STRICTNESS, so that adding this fallback cannot narrow
  # the guard. They render in their own layout with a fixed palette and never
  # see a theme surface, so the page is NOT their ground — but the answer to
  # that is to keep failing unresolved, exactly as this lane did before the
  # fallback existed, rather than to skip the file. Skipping would mean a violet
  # written into a mailer stops being caught, which is a coverage LOSS dressed
  # up as a fix.
  def surface_or_page(path, chain)
    found = surface_from_chain(chain)
    return found if found

    path.to_s.match?(MAILER_VIEWS) ? nil : :page
  end

  # The series colours, resolved ONCE from the page that declares the tokens
  # and then hunted on EVERY scanned page.
  #
  # RESOLVING THEM PER PAGE WOULD MAKE THE LANE PAGE-LOCAL, which is the whole
  # property this scan exists to have. Any other view declares no `--fc-goals`,
  # so a bare `#B8B0FF` written there would match nothing and sail through —
  # the guard would only ever police the one file that happens to define the
  # token. What is being hunted is the COLOUR, wherever it is written.
  def series_palette(mode)
    @series_palette ||= {}
    @series_palette[mode] ||= begin
      path = Rails.root.join(SLATE_PAGE).to_s
      page = tokens(mode).merge(embedded_style_tokens(path, mode))
      INLINE_SERIES.each_with_object({}) do |(name, series), out|
        [ series[:fill], series[:ink] ].compact.each do |token|
          raw = page[token] or flunk "#{SLATE_PAGE} declares no #{token} in the #{mode} theme"
          color = static_color(raw, page) or flunk "#{token} does not resolve statically in the #{mode} theme"
          out[color.upcase] ||= name
        end
      end
    end
  end

  # Every colour the inline lane stops on, mapped to the series that owns it.
  # The brand violet pair maps to nil: it is scanned wherever it is written
  # inline (the property PR 796 built this lane for) but it is a utility class
  # rather than a series, so it carries no page token to attribute to.
  def scanned_palette(mode, app)
    palette = {}
    [ ".text-violet", ".text-violet-ink" ].each do |klass|
      palette[opaque(last_rule_for(klass, "color")["color"], app).upcase] ||= nil
    end
    series_palette(mode).each { |color, name| palette[color] ||= name }
    palette
  end

  # Attribute a site to its series by the TOKEN NAME it actually writes, and
  # only fall back to the resolved colour for a bare hex. Two series can share
  # an ink — --fc-mult-ink and .text-violet-ink are both #C5C0FE — so colour
  # alone cannot tell them apart, while the token name can.
  def series_for(expr, color, palette)
    named = INLINE_SERIES.find do |_, series|
      [ series[:fill], series[:ink] ].compact.any? { |t| expr.match?(/#{Regexp.escape(t)}(?![\w-])/) }
    end
    named ? named.first : palette[color.upcase]
  end

  def inline_series_sites(mode)
    app = tokens(mode)

    SCANNED.flat_map do |root|
      Dir[root.join("**/*.{erb,rb}")].flat_map do |path|
        rel = Pathname(path).relative_path_from(Rails.root).to_s
        page = app.merge(embedded_style_tokens(path, mode))
        palette = scanned_palette(mode, app)
        inline_style_colors(path).filter_map do |line, expr, chain|
          color = static_color(expr, page)
          next unless color && palette.key?(color.upcase)

          [ rel, line, expr, color, surface_or_page(path, chain), series_for(expr, color, palette) ]
        end
      end
    end
  end

  # The tag-helper twin of `inline_series_sites`. Same resolution path — page
  # tokens merged over app tokens, `static_color`, then the registered palette
  # — so a colour written as a tag-helper option is measured exactly like the
  # same colour written as a `style=` attribute.
  def tag_helper_series_sites(mode)
    app = tokens(mode)
    palette = scanned_palette(mode, app)

    SCANNED.flat_map do |root|
      Dir[root.join("**/*.{erb,rb}")].sort.flat_map do |path|
        rel = Pathname(path).relative_path_from(Rails.root).to_s
        page = app.merge(embedded_style_tokens(path, mode))
        tag_helper_style_colors(path).flat_map do |line, exprs|
          exprs.filter_map do |expr|
            color = static_color(expr, page)
            [ rel, line, expr, color ] if color && palette.key?(color.upcase)
          end
        end
      end
    end
  end

  def classes_for_testid(path, testid)
    tag = File.read(Rails.root.join(path))[/<[^>]*data-testid=["']#{Regexp.escape(testid)}["'][^>]*>/m]
    assert tag, "#{path} has no element with data-testid=#{testid.inspect}"
    tag[/class=["']([^"']*)["']/, 1].to_s.split.sort
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

  test "inline brand-series color declarations clear AA on their real surfaces in both themes" do
    THEME_SELECTORS.each_key do |mode|
      sites = inline_series_sites(mode)
      assert_operator sites.length, :>, 0,
                      "the inline lane found no brand-series text in the #{mode} theme; without a real site this guard is vacuous"

      # PER-SERIES vacuity. The whole-lane count above is satisfied by ONE
      # series, so it says nothing about the others — and "the others" is
      # exactly where the gap lived: this lane measured Turf Score and walked
      # past Goals and DK Score for a whole release. Reddening one member of a
      # loop proves nothing about member N, so every series that paints text
      # has to be FOUND painting text before its measurement means anything.
      painted = sites.group_by(&:last)
      INLINE_SERIES.select { |_, s| s[:paints_text] }.each_key do |name|
        assert_operator painted.fetch(name, []).length, :>, 0,
                        "the inline lane found no #{name} text in the #{mode} theme. Either the series stopped " \
                        "painting text (drop paints_text) or its ink token was renamed — until then its row in " \
                        "INLINE_SERIES asserts nothing."
      end

      INLINE_SERIES.reject { |_, s| s[:paints_text] }.each_key do |name|
        assert_empty painted.fetch(name, []),
                     "#{name} is registered as graphics-only but now paints text in the #{mode} theme. " \
                     "Give it an ink token and set paints_text, rather than letting a fill become small text."
      end

      sites.each do |path, line, expr, color, surface, series|
        assert surface, "#{path}:#{line} #{expr.inspect} names no enclosing theme surface, and no page " \
                        "fallback applies to it — resolve its ground rather than assuming one"
        ground = grounds(mode).fetch(surface.to_s)
        ratio = contrast(color, ground)
        assert_operator ratio, :>=, AA_TEXT,
                        "#{path}:#{line} inline #{expr} (#{series || 'brand violet'}) resolves to #{color} on the " \
                        "#{mode} #{surface} (#{ground}), #{format('%.2f', ratio)}:1; AA needs 4.5:1 for small text"
      end
    end
  end

  # ── the tag-helper `style:` lane ───────────────────────────────────────────

  test "the tag-helper style: blind spot is exactly the size this file says" do
    found = Hash.new(0)
    SCANNED.each do |root|
      Dir[root.join("**/*.{erb,rb}")].each do |path|
        lines = tag_helper_color_lines(path)
        found[Pathname(path).relative_path_from(Rails.root).to_s] = lines.length if lines.any?
      end
    end

    assert_equal TAG_HELPER_COLOR_SITES, found,
                 "the tag-helper `color:` sites moved. This number is the SIZE OF THE BLIND SPOT and it is " \
                 "asserted because a hand count of it was wrong by four (five, actually nine — see the header). " \
                 "Re-derive it, update TAG_HELPER_COLOR_SITES, and check whether the new site paints a series " \
                 "colour — the lane below measures it if it does."
    assert_equal 9, found.values.sum, "the header states NINE tag-helper `color:` lines; keep the two in step"

    # THE PARSEABLE SUBSET, which is the number the lane below actually works
    # over. It is SEVEN, not nine, and the gap is the whole reason the header
    # spells the partition out: tokens/_paypal_sdk's two `style: { color:
    # 'blue' }` are JS object literals, and `color: 'blue'` is a PayPal funding
    # enum rather than a colour. If this ever equals the nine above, the value
    # pattern in `tag_helper_style_colors` has started swallowing quoted JS and
    # the lane is resolving strings that are not CSS.
    parseable = SCANNED.sum do |root|
      Dir[root.join("**/*.{erb,rb}")].sum { |path| tag_helper_style_colors(path).length }
    end
    assert_equal 7, parseable,
                 "#{parseable} tag-helper `style:` lines yield a parseable CSS colour, not 7. The header " \
                 "partitions the blind spot 9 matched / 7 parseable / 3 registered — re-derive all three."
  end

  test "a tag-helper style: option may not paint a series colour that fails AA" do
    THEME_SELECTORS.each_key do |mode|
      sites = tag_helper_series_sites(mode)

      assert_equal TAG_HELPER_SERIES_SITES.fetch(mode), sites.map { |rel, line, _, _| [ rel, line ] },
                   "the tag-helper sites painting a registered series colour in the #{mode} theme changed. " \
                   "An entry appearing under `light` is the tripwire firing: nothing resolved to a series " \
                   "colour there when this was written."

      sites.each do |rel, line, expr, color|
        # EVERY BARE SURFACE, not one resolved ground, and that is deliberate.
        # A blanked line has no element, so the ancestor walk cannot answer
        # what this sits on — and the two grounds these sites really have
        # DIFFER (error_logs is on the page, seasons/index is in a card), so
        # picking one would be the guess that the surface-exemption tests below
        # exist to stop. Clearing all four clears whichever it is.
        #
        # The violet TINT grounds are excluded on purpose: they are a
        # slates/benchmarks pattern that no tag-helper site sits on, and
        # --color-primary-ink is 4.23:1 on bg-violet/20 over the card, so
        # including them would red on a ground these elements are not on —
        # the same error in the other direction.
        SURFACES.each_key do |surface|
          ground = grounds(mode).fetch(surface.to_s)
          ratio = contrast(color, ground)

          assert_operator ratio, :>=, AA_TEXT,
                          "#{rel}:#{line} paints #{expr} (#{color}) through a tag-helper `style:` option, and it " \
                          "is #{format('%.2f', ratio)}:1 on the #{mode} #{surface} (#{ground}). This lane cannot " \
                          "see which surface the element sits on, so a registered colour written here must clear " \
                          "AA on all four — use the series' -ink token."
        end
      end
    end
  end

  # THE CONTROL FOR THE LANE ABOVE, and it has to be three separate halves
  # because each could rot on its own and each would leave the lane green: the
  # scanner could stop finding tag-helper lines, the palette could stop
  # recognising a series fill, and the ratio could stop being a failure. The
  # planted file lives in a TMPDIR rather than under app/views, because a
  # fixture written into a scanned directory is read by the sibling forks CI
  # runs this suite in.
  test "control: the tag-helper lane finds a planted site and the fill it writes fails" do
    Dir.mktmpdir do |dir|
      path = File.join(dir, "planted.html.erb")
      File.write(path, %(  <%= tag.span "x", class: "badge", style: "color: var(--fc-goals)" %>\n))

      assert_equal [ [ 1, [ "var(--fc-goals)" ] ] ], tag_helper_style_colors(path),
                   "the tag-helper scanner no longer finds a planted `style:` option — the lane above is blind"
    end

    page = tokens(:light).merge(embedded_style_tokens(Rails.root.join(SLATE_PAGE).to_s, :light))
    color = static_color("var(--fc-goals)", page)
    assert_equal "#B8B0FF", color.to_s.upcase, "--fc-goals no longer resolves to the Goals fill"
    assert scanned_palette(:light, tokens(:light)).key?(color.upcase),
           "the palette no longer recognises the Goals fill, so the lane would walk past it"

    ratio = contrast(color, grounds(:light).fetch("card"))
    assert_operator ratio, :<, AA_TEXT,
                    "the Goals fill now clears AA on the light card at #{format('%.2f', ratio)}:1; if that is real " \
                    "the lane above can no longer fail on it, and this control is asserting nothing"
  end

  # THE CLAIM THE COMMENTS MAKE ABOUT WHERE THESE INKS COME FROM. Both the
  # slates/show comment and docs/FORMULAS.md said the borrowed inks were
  # "derived per theme by Studio::ThemeResolver" and therefore tracked a theme
  # change. They are not and do not — they are this app's own tokens. That was
  # corrected in prose, and prose is what went wrong the first time, so the
  # corrected claim is asserted here: if the resolver ever DOES emit one, this
  # reds and the comments get to be right again.
  test "control: the borrowed inks are the app's own tokens, not the resolver's" do
    colors = ThemeSetting.current.resolved_colors

    %i[dark light].each do |mode|
      emitted = engine_tokens(mode, colors)

      [ "--color-primary-ink", "--color-violet-ink" ].each do |token|
        refute emitted.key?(token),
               "Studio::ThemeResolver now emits #{token} in the #{mode} theme. slates/show.html.erb and " \
               "docs/FORMULAS.md both say it does NOT, and that the four ink values pin rather than track — " \
               "update them, because the resolver-derived version is the better story and would now be true."
      end

      assert emitted.key?("--color-primary"),
             "the resolver stopped emitting --color-primary in the #{mode} theme, so this control can no longer " \
             "tell 'the resolver does not emit the ink' from 'the resolver emitted nothing'"
    end

    app = app_tokens(compiled_css, THEME_SELECTORS[:dark])
    assert app.key?("--color-primary-ink"), "--color-primary-ink is no longer declared by this app's own CSS"
    assert app.key?("--color-violet-ink"), "--color-violet-ink is no longer declared by this app's own CSS"
  end

  test "the slate bye-line badge uses the benchmarks badge treatment" do
    benchmark = classes_for_testid("app/views/benchmarks/index.html.erb", "benchmarks-bye-badge")
    slate = classes_for_testid("app/views/slates/show.html.erb", "bye-line-badge")

    assert_equal benchmark, slate,
                 "the two pages describe the same bye line; keep their small violet label treatment identical"
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

  # ── the series inks, measured per member ───────────────────────────────────

  # Every ground a series fill FAILS on as text — the defect each ink exists to
  # answer. One row per (series, theme, ground), because a control that covers
  # only the first member of a list says nothing about the rest, and "the rest"
  # is where this card's two defects lived. The third row is the pair of Save
  # Formula buttons, which name no surface and sit on the page.
  SERIES_FILL_FAILURES = [
    { series: "Goals", token: "--fc-goals", mode: :light, surface: "card", was: 1.96 },
    { series: "DK Score", token: "--fc-dk-score", mode: :dark, surface: "card", was: 2.22 },
    { series: "DK Score", token: "--fc-dk-score", mode: :dark, surface: "page", was: 3.48 }
  ].freeze

  # What each ink measures on the grounds its text actually sits on. Pinned so
  # that editing a hex in the page's <style> block cannot quietly move a ratio.
  SERIES_INK_FIGURES = [
    { token: "--fc-goals-ink", mode: :light, surface: "card", ratio: 6.03 },
    { token: "--fc-goals-ink", mode: :dark, surface: "card", ratio: 5.68 },
    { token: "--fc-dk-score-ink", mode: :light, surface: "card", ratio: 5.02 },
    { token: "--fc-dk-score-ink", mode: :light, surface: "page", ratio: 4.79 },
    { token: "--fc-dk-score-ink", mode: :dark, surface: "card", ratio: 5.54 },
    { token: "--fc-dk-score-ink", mode: :dark, surface: "page", ratio: 8.68 }
  ].freeze

  def slate_token(name, mode)
    path = Rails.root.join(SLATE_PAGE).to_s
    page = tokens(mode).merge(embedded_style_tokens(path, mode))
    raw = page[name] or flunk "#{SLATE_PAGE} declares no #{name} in the #{mode} theme"
    static_color(raw, page) or flunk "#{name} does not resolve to a static colour in the #{mode} theme"
  end

  test "control: each series fill still fails AA as text on the ground its text sits on" do
    SERIES_FILL_FAILURES.each do |row|
      fill = slate_token(row[:token], row[:mode])
      ground = grounds(row[:mode]).fetch(row[:surface])
      ratio = contrast(fill, ground)

      assert_operator ratio, :<, AA_TEXT,
                      "#{row[:token]} (#{fill}) now measures #{format('%.2f', ratio)}:1 on the #{row[:mode]} " \
                      "#{row[:surface]}; if the fill clears on its own, #{row[:series]}'s ink is pointless and " \
                      "this lane would pass on the unfixed markup"
      assert_in_delta row[:was], ratio, 0.01,
                      "the #{row[:mode]} #{row[:surface]} measured #{row[:was]}:1 for #{row[:series]} when this was built"
    end
  end

  test "each series ink clears AA on the grounds its text sits on" do
    SERIES_INK_FIGURES.each do |row|
      ink = slate_token(row[:token], row[:mode])
      ground = grounds(row[:mode]).fetch(row[:surface])
      ratio = contrast(ink, ground)

      assert_operator ratio, :>=, AA_TEXT,
                      "#{row[:token]} (#{ink}) on the #{row[:mode]} #{row[:surface]} (#{ground}) is " \
                      "#{format('%.2f', ratio)}:1; AA needs 4.5:1 for small text"
      assert_in_delta row[:ratio], ratio, 0.01,
                      "#{row[:token]} on the #{row[:mode]} #{row[:surface]} measured #{row[:ratio]}:1 when this was built"
    end
  end

  # Neither ink may collapse back onto its own fill: that is what "per theme"
  # buys, and a copy-paste that points both themes at one value would otherwise
  # pass every ratio above in the theme that happens to clear.
  test "control: each series ink differs from its fill in the theme the fill fails" do
    SERIES_FILL_FAILURES.each do |row|
      ink_token = "#{row[:token]}-ink"
      refute_equal slate_token(row[:token], row[:mode]).upcase, slate_token(ink_token, row[:mode]).upcase,
                   "#{ink_token} resolves to the fill in the #{row[:mode]} theme, where the fill is " \
                   "#{row[:was]}:1 — the ink must be per theme, not an alias of the colour it replaces"
    end
  end

  # The page fallback is only honest while the layout really paints bg-page. If
  # the body stops carrying it, every element that names no surface of its own
  # is being measured against a ground it is not on — starting with the two
  # Save Formula buttons, which is the whole reason the fallback exists.
  test "the page fallback is the layout's real background" do
    body = File.read(Rails.root.join("app/views/layouts/application.html.erb"))[/<body[^>]*>/m]
    assert body, "the app layout has no <body> tag to read a background from"
    assert_includes body[/class="([^"]*)"/, 1].to_s.split, "bg-page",
                    "surface_or_page measures an unmarked element against the page; the layout body must paint bg-page"
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
