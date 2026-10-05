require "test_helper"

# Component tier for the LOGOTYPE colour (task: wordmark-returns-to-brand-green).
#
# "Turf Monster" set as a logotype wears the brand green #4BAF50 in both themes.
# It used to take `text-primary`, so the 2026-09-16 contrast fix repainted it as
# a side effect: #81C784 in the dark navbar, #2E7D32 in the light one and in the
# engine footer. It now reads its own token, --tm-wordmark, declared beside the
# primary ink in app/assets/tailwind/application.css.
#
# WHAT IS MEASURED. The COMPILED stylesheet (app/assets/builds/tailwind.css,
# which CI builds before the suite), not the source: which rule paints
# `.tm-wordmark` and the footer accent, what the token resolves to, and that no
# theme block redefines it. The browser half (the colour actually painting, and
# the engine's later inline style block losing to this rule) is
# e2e/wordmark_brand_green.spec.js.
#
# WHAT IS DELIBERATELY NOT ASSERTED: a contrast ratio. A logotype is exempt from
# WCAG 1.4.3, and #4BAF50 on the light page is 2.66:1. The exemption is why the
# last two tests exist: the token must not leak onto anything a person reads.
class WordmarkBrandGreenTest < ActiveSupport::TestCase
  BRAND_GREEN = "#4BAF50".freeze
  COMPILED_CSS = Rails.root.join("app/assets/builds/tailwind.css").freeze
  VIEWS = Rails.root.join("app/views").freeze
  # Every place this app sets its own name as a logotype. The engine footer is
  # the sixth, and it is engine markup, so it is reached by selector instead.
  LOGOTYPE_SITES = %w[
    layouts/_navbar.html.erb
    shared/_auth_card.html.erb
    landing_pages/show.html.erb
    landing_pages/claimed.html.erb
    pages/turf_monster_v1.html.erb
  ].freeze
  LOGOTYPE_WORD = %r{<span class="([^"]*)">Monster</span>}

  def compiled_css
    @compiled_css ||= begin
      flunk "#{COMPILED_CSS} is missing — run `bin/rails tailwindcss:build` first" unless COMPILED_CSS.exist?
      COMPILED_CSS.read
    end
  end

  # Every leaf rule as [selectors without whitespace around commas, body].
  def rules
    @rules ||= compiled_css.scan(/([^{}]+)\{([^{}]*)\}/).map { |sel, body| [sel.strip.split(/\s*,\s*/), body] }
  end

  def token_declarations
    rules.filter_map do |selectors, body|
      value = body[/(?<![\w-])--tm-wordmark\s*:\s*([^;}]+)/, 1]
      [selectors, value.strip] if value
    end
  end

  def painters
    rules.select { |_, body| body.match?(/(?<![\w-])color\s*:\s*var\(--tm-wordmark\)/) }.flat_map(&:first)
  end

  test "the wordmark token is the brand green, declared once, for both themes" do
    declared = token_declarations
    assert_equal [[[":root"], BRAND_GREEN.downcase]], declared.map { |sel, v| [sel, v.downcase] },
                 "--tm-wordmark must be declared exactly once, on :root, as #{BRAND_GREEN}. A second " \
                 "declaration under .dark or html:not(.dark) would make the logotype differ by theme again."
  end

  test "the app logotype class and the engine footer accent both read the token" do
    assert_includes painters, ".tm-wordmark", "no compiled rule paints .tm-wordmark with var(--tm-wordmark)"
    assert_includes painters, ".ftr .ftr-wordmark-accent",
                    "the footer accent word must be painted by a TWO-class selector: the engine styles " \
                    ".ftr-wordmark-accent from an inline block later in the document, and one class would lose to it"
  end

  test "every logotype site wears the wordmark class and not the text ink" do
    LOGOTYPE_SITES.each do |site|
      classes = VIEWS.join(site).read.scan(LOGOTYPE_WORD).flatten
      assert_equal 1, classes.size, "#{site} should set the word Monster as a logotype exactly once"
      assert_includes classes.first.split, "tm-wordmark", "#{site}: the logotype lost the brand green"
      refute_includes classes.first.split, "text-primary",
                      "#{site}: text-primary on the logotype repaints it with the per-theme ink (#81C784 in dark)"
    end
  end

  test "no other view sets the word Monster as a coloured logotype" do
    found = Dir[VIEWS.join("**/*.erb")].select { |path| File.read(path).match?(LOGOTYPE_WORD) }
                                       .map { |path| path.delete_prefix("#{VIEWS}/") }
    assert_equal LOGOTYPE_SITES.sort, found.sort,
                 "a logotype was added or removed; list it in LOGOTYPE_SITES so its colour is guarded"
  end

  # ── the exemption must not leak ──────────────────────────────────────────────

  test "the token paints nothing but the logotype" do
    assert_equal [".ftr .ftr-wordmark-accent", ".tm-wordmark"], painters.sort,
                 "--tm-wordmark is 2.66:1 on the light page: legal for a logotype, a failure for text"
    uses = compiled_css.scan(/var\(--tm-wordmark\)/).size
    assert_equal 1, uses, "--tm-wordmark is read #{uses} times in the compiled CSS; only the logotype rule may read it"

    carriers = Dir[VIEWS.join("**/*.erb")].select { |path| File.read(path).match?(/(?<![\w-])tm-wordmark(?![\w-])/) }
                                          .map { |path| path.delete_prefix("#{VIEWS}/") }
    assert_equal LOGOTYPE_SITES.sort, carriers.sort, "tm-wordmark is for the logotype sites only"
  end

  test "the theme primary and the footer's own variable are left alone" do
    assert_equal "#2E7D32", ThemeSetting.current.resolved_colors.fetch(:primary).upcase,
                 "the 2026-09-16 contrast fix stays: the primary is still the darker fill"
    refute_match(/--ftr-primary\s*:/, Rails.root.join("app/assets/tailwind/application.css").read,
                 "--ftr-primary also paints the footer's link hovers and social chips; " \
                 "recolour the wordmark by its element, not by this variable")
  end

  # The reason the footer is reached by element: in the engine, one variable
  # paints the accent word AND the link hover. If the engine ever splits them,
  # this fails and the override can become a variable instead.
  test "pin: the engine footer paints the accent and the link hover from one variable" do
    assets = File.read(File.join(Gem.loaded_specs.fetch("studio-engine").full_gem_path,
                                 "app/views/studio/site_footer/_assets.html.erb"))
    assert_match(/\.ftr-wordmark-accent\s*\{\s*color:\s*var\(--ftr-primary\)/, assets)
    assert_match(/\.ftr-link:hover[^{]*\{\s*color:\s*var\(--ftr-primary\)/, assets)
  end
end
