require "test_helper"

# Unit tier for THE BRAND FITS OR IT IS THE MASCOT (/tasks/turf-navbar-logo-when-tight).
#
# Alex McRitchie, on a truncated "T… Mo…" and a stacked "Turf / Monster" in the
# navbar: "You should use the navbar logo." The rule this pins, read from the
# COMPILED stylesheet (app/assets/builds/tailwind.css, which CI builds before
# the suite) and the live navbar's markup:
#
#   · below 768px the title is a ROW again, over the engine's column: no stack
#   · a tight header hides the words for the eye only (out of flow, a 1px
#     clipped box), never with visibility (which keeps their room) and never
#     with display: none (which drops the page's h1)
#   · the measure state puts them back in flow, and nothing in the row shrinks
#   · the script that decides is pinned and imported, and the mascot keeps
#     the name "Turf Monster"
#
# The browser half (one line or not drawn at 360 to 1280, a chip that hydrates
# wider, the scroll collapse) is e2e/navbar_brand_fit.spec.js; the script's
# own logic is test/javascript/nav_brand_fit.test.mjs.
class NavbarBrandFitTest < ActionDispatch::IntegrationTest
  COMPILED_CSS = Rails.root.join("app/assets/builds/tailwind.css").freeze

  def css
    @css ||= begin
      flunk "#{COMPILED_CSS} is missing — run `bin/rails tailwindcss:build` first" unless COMPILED_CSS.exist?
      COMPILED_CSS.read
    end
  end

  # The declaration block of the first rule whose selector list is exactly
  # `selector`, compared minified (the build drops the spaces around , and >).
  def block_for(selector, within: css)
    want = squeeze(selector)
    within.scan(/([^{}]+)\{([^{}]*)\}/).each do |sel, body|
      return body if squeeze(sel) == want
    end
    nil
  end

  # Every declaration block whose selector list names `selector` among others:
  # the minifier merges rules that declare the same thing.
  def blocks_naming(selector)
    want = squeeze(selector)
    css.scan(/([^{}]+)\{([^{}]*)\}/).filter_map { |sel, body| body if squeeze(sel).split(",").include?(want) }
  end

  def assert_never_shrinks(selector)
    assert blocks_naming(selector).any? { |body| body.match?(/flex-shrink:\s*0/) },
           "no rule gives #{selector} flex-shrink: 0"
  end

  def squeeze(selector)
    selector.gsub(/\s+/, " ").gsub(/\s*([>,+~])\s*/, "\\1").strip
  end

  def phone_band
    start = css.index(/@media \(max-width:\s*767px\)\s*\{\s*\.nav-shell \.nav-title\s*\{/)
    assert start, "the phone band no longer opens with this app's .nav-shell .nav-title rule"
    css[start, 400]
  end

  test "below 768px the title is one row, not the engine's stacked column" do
    band = phone_band
    title = band[/\.nav-shell \.nav-title\s*\{([^}]*)\}/, 1]
    assert_match(/flex-direction:\s*row/, title)
    refute_match(/flex-direction:\s*column/, title)
  end

  test "a tight header hides the words out of flow and clipped, never by visibility or display" do
    body = block_for('.nav-shell[data-nav-brand="tight"]:not([data-nav-brand-measure]) .nav-title') ||
           block_for(".nav-shell[data-nav-brand=tight]:not([data-nav-brand-measure]) .nav-title")
    assert body, "no rule hides the title on a tight header"
    assert_match(/position:\s*absolute/, body)
    assert_match(/width:\s*1px/, body)
    assert_match(/height:\s*1px/, body)
    assert_match(/overflow:\s*hidden/, body)
    assert_match(/clip-path:\s*inset\(50%\)/, body)
    refute_match(/visibility/, body, "visibility keeps the words' room: the mascot would sit beside a gap")
    refute_match(/display:\s*none/, body, "display: none drops the page's h1 from the accessibility tree")
    refute_match(/text-overflow/, body)
  end

  test "the first-paint guess hides the same way and yields to the script's answer" do
    guesses = css.scan(/@container nav-brand-row \(([^)]*)\)/).flatten
    assert_equal 3, guesses.size, "one guess per type band (<400, 400-767, 768+)"
    guess_rules = css.scan(/\.nav-shell:not\(\[data-nav-brand\]\) \.nav-title\s*\{([^}]*)\}/).flatten
    assert_equal 3, guess_rules.size
    guess_rules.each do |rule|
      assert_match(/position:\s*absolute/, rule)
      assert_match(/clip-path:\s*inset\(50%\)/, rule)
    end
    container = block_for(".nav-shell > .nav-row > div:first-child")
    assert container, "the left column is not the size container"
    assert_match(/container:\s*nav-brand-row\s*\/\s*inline-size/, container)
  end

  test "while measuring, nothing in the row may shrink" do
    assert_never_shrinks(".nav-shell[data-nav-brand-measure] .nav-logo-link")
    assert_never_shrinks(".nav-shell[data-nav-brand-measure] .nav-row nav")
  end

  test "the mascot never gives way to the row" do
    assert_never_shrinks(".nav-shell[data-nav-brand=tight] .nav-logo-link")
    assert_never_shrinks(".nav-shell .nav-logo-link > .nav-logo")
  end

  test "the deciding script is pinned and imported" do
    assert_match(/^pin "nav_brand_fit"$/, Rails.root.join("config/importmap.rb").read)
    assert_match(/^import "nav_brand_fit"$/, Rails.root.join("app/javascript/application.js").read)
  end

  test "the live navbar renders the hooks the rule keys on, and the mascot keeps its name" do
    get contests_path
    assert_response :success
    doc = Nokogiri::HTML(response.body)
    header = doc.at_css("header.nav-shell[data-navbar-root]")
    assert header, "no live navbar"
    assert_match(/nav-collapse/, header["data-studio-controller"].to_s)
    row = header.at_css(".nav-row > div:first-child")
    link = row.at_css(".nav-logo-link")
    assert link, "the logo link is not in the left column"
    assert_equal "Turf Monster", link.at_css("img.nav-logo")["alt"]
    assert_equal %w[Turf Monster], link.css(".nav-title > span").map(&:text)
  end
end
