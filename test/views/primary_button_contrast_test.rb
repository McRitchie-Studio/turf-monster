require "test_helper"

# Component tier for the house primary button's label contrast
# (task: primary-button-fails-contrast).
#
# `.btn-primary` is the primary button in 69 view files. Until 2026-09-16 it
# painted a white label on #4BAF50 at 2.78:1, below WCAG AA's 4.5:1 for its
# 16px bold text. Mr. McRitchie chose to darken the brand primary to #2E7D32
# and keep the white label: 5.13:1 at rest, 8.46:1 on hover.
#
# WHAT THIS MEASURES, AND WHY IT IS NOT A HEX CHECK. A hex assertion passes
# while someone changes which variable feeds the button. So every ratio below
# is computed from what actually ships:
#   * the FILL comes from the CSS the engine emits into <head>
#     (Studio::ThemeResolver#to_css over ThemeSetting.current.resolved_colors,
#     the same path as studio_theme_css_tag), read per theme;
#   * WHICH variable is the fill, at rest and on hover, and what the LABEL
#     resolves to, are read from the engine's own `@utility btn-primary`.
# If the engine rewires the button, the parse follows it or fails loudly.
#
# WHAT IT CANNOT SEE. A ThemeSetting row saved from /admin/theme overrides
# config.theme_primary per environment, and the test database has none. On
# 2026-09-16 neither QA nor production had a row, so config was the live value.
class PrimaryButtonContrastTest < ActiveSupport::TestCase
  AA_TEXT = 4.5
  CHOSEN_PRIMARY = "#2E7D32".freeze
  RETIRED_PRIMARY = "#4BAF50".freeze

  ENGINE_CSS = Pathname.new(Gem.loaded_specs.fetch("studio-engine").full_gem_path)
                       .join("app/assets/tailwind/studio_engine/engine.css").freeze

  THEME_SELECTORS = { dark: ":root, .dark", light: "html:not(.dark)" }.freeze

  # WCAG 2.1 contrast, computed here rather than through Studio::ColorScale so
  # the engine's own helper is not the thing vouching for the engine's colours.
  def contrast(hex_a, hex_b)
    rel = lambda do |hex|
      r, g, b = expand_hex(hex).delete("#").scan(/../).map { |c| c.to_i(16) / 255.0 }
      lin = ->(v) { v <= 0.03928 ? v / 12.92 : ((v + 0.055) / 1.055)**2.4 }
      0.2126 * lin[r] + 0.7152 * lin[g] + 0.0722 * lin[b]
    end
    a, b = rel[hex_a], rel[hex_b]
    ([a, b].max + 0.05) / ([a, b].min + 0.05)
  end

  def expand_hex(hex)
    h = hex.delete("#")
    h = h.chars.map { |c| c * 2 }.join if h.length == 3
    "##{h.upcase}"
  end

  def emitted_theme_css(colors = ThemeSetting.current.resolved_colors)
    Studio::ThemeResolver.new(colors).to_css
  end

  # The custom properties one theme's block declares, as { "--name" => "value" }.
  def theme_tokens(css, mode)
    selector = THEME_SELECTORS.fetch(mode)
    body = css[/#{Regexp.escape(selector)}\s*\{([^}]*)\}/m, 1]
    flunk "the emitted theme CSS has no `#{selector}` block" unless body
    body.scan(/(--[\w-]+):\s*([^;]+);/).to_h { |name, value| [name, value.strip] }
  end

  # The engine's `@utility btn-primary`, split into its rest and hover bodies.
  def btn_primary_utility
    body = ENGINE_CSS.read[/@utility btn-primary\s*\{(.*?)\n\}/m, 1]
    flunk "no `@utility btn-primary` in #{ENGINE_CSS}" unless body
    hover = body[/&:hover\s*\{([^}]*)\}/m, 1]
    flunk "`@utility btn-primary` declares no &:hover block" unless hover
    { rest: body.sub(/&:hover\s*\{[^}]*\}/m, ""), hover: hover }
  end

  def declaration(body, property)
    value = body[/(?<![\w-])#{Regexp.escape(property)}:\s*([^;]+);/, 1]
    flunk "btn-primary declares no #{property}: in #{body.inspect}" unless value
    value.strip
  end

  # Resolve `var(--name, fallback)` (nested fallbacks included) against tokens.
  def resolve(expr, tokens)
    expr = expr.strip
    match = expr.match(/\Avar\(\s*(--[\w-]+)\s*(?:,\s*(.*))?\)\z/m)
    return expr unless match

    tokens.fetch(match[1]) do
      flunk "#{match[1]} is unset and has no fallback" unless match[2]
      resolve(match[2], tokens)
    end
  end

  # { rest: [label, fill], hover: [label, fill] } for one theme.
  def button_colors(css, mode)
    tokens = theme_tokens(css, mode)
    btn_primary_utility.transform_values do |body|
      [resolve(declaration(body, "color"), tokens), resolve(declaration(body, "background-color"), tokens)]
    end
  end

  # ── the decision, pinned ───────────────────────────────────────────────────

  test "the primary button's fill resolves to the chosen #2E7D32 in both themes" do
    css = emitted_theme_css
    THEME_SELECTORS.each_key do |mode|
      _label, fill = button_colors(css, mode)[:rest]
      assert_equal CHOSEN_PRIMARY, expand_hex(fill),
                   "btn-primary's rest fill in the #{mode} theme is #{fill}. #2E7D32 was Mr. McRitchie's " \
                   "choice on 2026-09-16. Changing the brand primary is his decision; if he made a new one, " \
                   "update this pin, and the contrast tests below still have to pass."
    end
  end

  test "the app keeps the engine's white label rather than overriding it" do
    declarations = Dir[Rails.root.join("app/{assets,views}/**/*.{css,erb}")].flat_map do |path|
      File.read(path).scan(/--btn-primary-fg(?:-hover)?\s*:/).map { path }
    end
    assert_empty declarations,
                 "Option B keeps the white label, so nothing may set --btn-primary-fg. Found in: #{declarations.uniq}"

    css = emitted_theme_css
    THEME_SELECTORS.each_key do |mode|
      button_colors(css, mode).each do |state, (label, _fill)|
        assert_equal "#FFFFFF", expand_hex(label), "btn-primary's #{state} label in the #{mode} theme"
      end
    end
  end

  # ── the property: the label clears AA on both fills, in both themes ─────────

  test "btn-primary's label clears AA on its rest and hover fills in both themes" do
    css = emitted_theme_css
    THEME_SELECTORS.each_key do |mode|
      button_colors(css, mode).each do |state, (label, fill)|
        ratio = contrast(label, fill)
        assert_operator ratio, :>=, AA_TEXT,
                        "btn-primary #{state} in the #{mode} theme is #{format('%.2f', ratio)}:1 " \
                        "(#{label} on #{fill}). WCAG AA needs 4.5:1 for its 16px bold label."
      end
    end
  end

  # ── control: the measurement bites on the green it replaced ─────────────────
  #
  # Without this, a parse that silently resolved the wrong variable could pass
  # every test above. Feed the retired primary through the SAME measurement and
  # it must fail at rest, at the 2.78:1 that opened this task.

  test "the same measurement fails the retired #4BAF50 at rest" do
    css = emitted_theme_css(Studio.theme_config.merge(primary: RETIRED_PRIMARY))
    THEME_SELECTORS.each_key do |mode|
      label, fill = button_colors(css, mode)[:rest]
      assert_equal RETIRED_PRIMARY, expand_hex(fill), "the control must actually measure the retired green"
      assert_in_delta 2.78, contrast(label, fill), 0.01,
                      "white on #4BAF50 measured 2.78:1 when this task opened; a different number means " \
                      "the measurement changed, not the colour"
    end
  end
end
