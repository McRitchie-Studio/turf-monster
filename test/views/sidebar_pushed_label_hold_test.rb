# frozen_string_literal: true

require "test_helper"

# [component] The opponent labels inside a card the picks sidebar is squeezing.
#
# THE DEFECT. `contests/_multi_week_team_card` steps its opponent labels up at
# `lg` on a premise it states in its own comment — the card "only reaches ~236px
# at 1024px". True with the sidebar CLOSED, false with it OPEN: the push cascade
# takes 320px away, so at `lg` the labels grow exactly while the card is at its
# narrowest. From 1120px (where SidebarPushedGridTest's 2-up fallback ends and
# four cards go back across the pushed column at ~180px) up to 1343.98px (where
# the push steps 20rem -> 15rem and the card regains ~240px), a 180px card wore
# 14px abbreviations: measured cart-open at 1120, all 32 abbreviations clipped
# and every "Week n" wrapped. One pixel lower, at 1119, the same board read
# "Commanders" and "SEA / PIT / JAX" in full.
#
# THE FIX holds the SMALL variant across that band, under `.tm-sidebar-pushed`.
#
# WHY THIS FILE IS SHAPED THE WAY IT IS. The hold is a seam — one stylesheet
# block keyed on three classes in one ERB file, live only inside one viewport
# band — and seams rot silently: rename a hook, add a fourth `lg:` step, or move
# the 1344px push step, and nothing errors, the labels just clip again the next
# time someone opens the cart. So this does not hard-code the held values. It
# READS the small variant out of the partial and requires the stylesheet to
# match it, and it requires the band's two edges to equal the two numbers they
# were derived from. Sibling: test/views/sidebar_pushed_grid_test.rb.
class SidebarPushedLabelHoldTest < ActiveSupport::TestCase
  APP_CSS = Rails.root.join("app/assets/tailwind/application.css")
  CARD    = Rails.root.join("app/views/contests/_multi_week_team_card.html.erb")

  HOLD_QUERY = /@media \(min-width: 1120px\) and \(max-width: 1343\.98px\) \{(.*?)\n\}/m

  # Every Tailwind token this file has to resolve to a CSS value. An `lg:` step
  # whose base token is missing here FAILS rather than passing quietly — that is
  # the point: a new step-up must be considered, not absorbed.
  TOKENS = {
    "px-px"       => "1px",
    "px-1"        => "0.25rem",
    "gap-0.5"     => "0.125rem",
    "gap-1"       => "0.25rem",
    "text-[9px]"  => "9px",
    "text-[10px]" => "10px",
    "text-sm"     => "0.875rem"
  }.freeze

  # class attr -> the tokens that have an `lg:` counterpart in the same attr
  def stepped_pairs(class_attr)
    class_attr.scan(/lg:(\S+)/).flatten.filter_map do |large|
      base = large.sub(/-\[.*\]\z/) { "" }
      family = large[/\A[a-z-]+?(?=-)/] || large
      small = class_attr[/(?<![\w:-])#{Regexp.escape(family)}-\S+/]
      next if small.nil? || small == "lg:#{large}"

      [small, large]
    end
  end

  def hold_block
    APP_CSS.read[HOLD_QUERY, 1]
  end

  def card_line(hook)
    CARD.read.lines.find { |l| l.include?(hook) } ||
      flunk("app/views/contests/_multi_week_team_card.html.erb no longer carries .#{hook} — " \
            "the hold rule for it is dead CSS")
  end

  test "the hold block exists and sits unlayered so lg: cannot win it back" do
    css     = APP_CSS.read
    rule_at = css.index(HOLD_QUERY)

    assert rule_at, "no sidebar-open label-hold @media block in application.css"

    prefix = css[0...rule_at]

    assert_equal prefix.count("{"), prefix.count("}"),
                 "the hold must sit at the top level, not inside an @layer block — layered CSS " \
                 "cannot outrank lg:text-sm"
  end

  test "the band abuts the 2-up fallback exactly, with no gap and no overlap" do
    css = APP_CSS.read

    assert_match(/max-width: 1119\.98px/, css,
                 "the 2-up fallback's upper edge moved; the hold opens at 1120px on the premise " \
                 "that four cards resume there")
    assert_match(/@media \(min-width: 1120px\)/, css,
                 "the hold must open at exactly the width the fallback closes at — a gap between " \
                 "them is a band of clipped labels with no rule covering it")
  end

  test "the band closes where the push cascade gives the card its width back" do
    assert_match(/@media \(min-width: 1344px\) \{ \.tm-sidebar-pushed \{ margin-right: 15rem; \} \}/,
                 APP_CSS.read,
                 "the hold ends at 1343.98px because 1344px is where the push steps 20rem -> 15rem " \
                 "and the card regains ~240px; move that step and the hold ends at the wrong width")
  end

  test "the held values ARE the small variant, read out of the partial" do
    block = hold_block

    assert block, "the hold block must exist"

    {
      "tm-opponent-cell" => { "px"       => %w[padding-left padding-right] },
      "tm-opponent-week" => { "text"     => %w[font-size] },
      "tm-opponent-row"  => { "gap"      => %w[gap] }
    }.each do |hook, families|
      line = card_line(hook)

      families.each_key do |family|
        small = line[/(?<![\w:-])#{family}-\S+?(?=["\s])/]

        assert small, "expected a `#{family}-*` on .#{hook}"

        value = TOKENS[small] ||
                flunk("unmapped Tailwind token `#{small}` on .#{hook} — add it to TOKENS and " \
                      "decide whether the hold still holds the right value")

        families[family].each do |prop|
          assert_match(/\.tm-sidebar-pushed \.#{hook}\s*\{[^}]*#{prop}:\s*#{Regexp.escape(value)}/, block,
                       "the hold gives .#{hook} a different #{prop} than the partial's own small " \
                       "variant (`#{small}` = #{value}) — the band would render a third size that " \
                       "exists nowhere else")
        end
      end
    end
  end

  test "the abbreviation spans are held at the partial's own small size" do
    span  = CARD.read.lines.find { |l| l.include?("opponent.short_name") }
    small = span[/(?<![\w:-])text-\S+?(?=["\s])/]
    value = TOKENS[small] || flunk("unmapped token `#{small}` on the abbreviation span")

    assert_match(/\.tm-opponent-row span\s*\{[^}]*font-size:\s*#{Regexp.escape(value)}/, hold_block,
                 "the abbreviation is what clipped; holding the row's gap without holding the " \
                 "span's font-size fixes nothing")
    assert_match(/\.tm-opponent-row span\s*\{[^}]*line-height:\s*inherit/, hold_block,
                 "text-sm also sets line-height: 1.25rem, which overrides the row's leading-none — " \
                 "without resetting it the band gets the small font in a large line box")
  end

  # The rot guard. Every element inside the opponent block that steps a held
  # family up at `lg:` must be reachable from the hold — either it carries a
  # hook the hold names, or it is a span the row's descendant selector covers.
  # A new stepped element with neither is a new way for the band to grow while
  # the card cannot, and it would otherwise land silently.
  HELD_FAMILIES = %w[text px py p gap].freeze

  test "every lg: step-up in the opponent block is reachable from the hold" do
    body  = CARD.read[/<div class="tm-opponent-cell.*?<\/div>\n\s*<% end %>/m].to_s
    block = hold_block

    refute_empty body, "could not slice the opponent block out of the partial"
    assert_includes body, "opponent.short_name",
                    "the slice must reach the abbreviation span — it is the element that clipped"

    tags = body.scan(/<(\w+)\s[^>]*class="([^"]*lg:[^"]*)"/m)

    assert_operator tags.size, :>=, 3,
                    "expected the cell, the week label and the abbreviation row to step up at lg"

    tags.each do |tag, attr|
      stepped = stepped_pairs(attr).select do |_small, large|
        HELD_FAMILIES.include?(large[/\A[a-z]+/])
      end
      next if stepped.empty?

      hooks = attr.scan(/tm-opponent-[\w-]+/)

      if hooks.any?
        hooks.each do |hook|
          assert_includes block, ".tm-sidebar-pushed .#{hook}",
                          "<#{tag}> steps #{stepped.map(&:last).join(', ')} up at lg and carries " \
                          ".#{hook}, but the hold never names that hook — inside the band it grows " \
                          "while the card cannot"
        end
      else
        assert_equal "span", tag,
                     "<#{tag}> steps #{stepped.map(&:last).join(', ')} up at lg with no " \
                     "tm-opponent-* hook and is not a span the row selector covers — add a hook " \
                     "and hold it, or the band clips again"
        assert_includes block, ".tm-sidebar-pushed .tm-opponent-row span",
                         "the hold must cover the row's spans for #{stepped.map(&:last).join(', ')}"
      end
    end
  end
end
