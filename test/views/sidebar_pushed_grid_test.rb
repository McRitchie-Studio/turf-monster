# frozen_string_literal: true

require "test_helper"

# [component] The contest board's card grids and the picks sidebar that squeezes
# them.
#
# THE DEFECT. `.tm-sidebar-pushed` reserves 20rem of margin for the fixed 320px
# picks sidebar the moment a pick is made. The grids inside it add columns at
# `md:` — a VIEWPORT query, which cannot see the reservation — so from 768px to
# 1120px four cards were laid across a 416-672px column and each came out
# 93-162px wide: narrower than the same card gets on a 390px phone, with the
# city truncated to "Balti...", the mascot to "R...", and three "Week n" labels
# overlapping into "WEEKWEEKWEEK".
#
# THE FIX IS A SEAM, AND SEAMS ROT SILENTLY. One stylesheet rule keyed on a
# class in one ERB file, live only inside one viewport band. Rename either half,
# widen the sidebar, or add a fifth grid without the hook, and nothing errors —
# the cards just squish again the next time someone makes a pick. So this pins
# BOTH ends plus the arithmetic the band was derived from.
class SidebarPushedGridTest < ActiveSupport::TestCase
  APP_CSS = Rails.root.join("app/assets/tailwind/application.css")
  BOARD   = Rails.root.join("app/views/contests/_turf_totals_board.html.erb")
  PANEL   = Rails.root.join("app/views/components/_sidebar_panel.html.erb")

  # The band: md (where the push starts) up to the crossover at 1120px.
  FALLBACK_QUERY = /@media \(min-width: 768px\) and \(max-width: 1119\.98px\) \{(.*?)\n\}/m

  def fallback_block
    APP_CSS.read[FALLBACK_QUERY, 1]
  end

  test "the pushed column falls back to the mobile layout below the crossover" do
    block = fallback_block

    assert block, "no sidebar-open fallback @media block in application.css"
    assert_match(/\.tm-sidebar-pushed \.tm-team-grid \{[^}]*grid-template-columns:\s*repeat\(2,/, block,
                 "the four-up team grids must drop to the phone's two columns while the cart is open")
    assert_match(/\.tm-sidebar-pushed \.tm-pair-grid \{[^}]*grid-template-columns:\s*repeat\(1,/, block,
                 "the two-up game-pair grid must drop to the phone's single column while the cart is open")
  end

  test "the fallback is unlayered so it outranks md:grid-cols-4" do
    css     = APP_CSS.read
    rule_at = css.index(FALLBACK_QUERY)

    assert rule_at, "the fallback rule must exist"

    # Tailwind's utilities are layered and author CSS at the top level beats
    # them. Balanced braces up to the rule means it is not nested in an @layer.
    prefix = css[0...rule_at]

    assert_equal prefix.count("{"), prefix.count("}"),
                 "the fallback must sit at the top level, not inside an @layer block"
  end

  test "every board grid that adds columns at md carries a fallback hook" do
    hooked = BOARD.read.lines.each_with_index.select { |line, _| line.include?("md:grid-cols-") }

    assert_operator hooked.size, :>=, 4, "expected the board's four card grids"

    hooked.each do |line, index|
      assert_match(/tm-team-grid|tm-pair-grid/, line,
                   "app/views/contests/_turf_totals_board.html.erb:#{index + 1} adds columns at md " \
                   "with no fallback hook, so it squishes behind the picks sidebar")
    end
  end

  test "the hooks live under the class the picks sidebar actually toggles" do
    board = BOARD.read

    assert_includes board, "'tm-sidebar-pushed': cartOpen",
                    "the fallback fires only under .tm-sidebar-pushed; if the board stops applying " \
                    "it on cartOpen the rule is dead CSS"
    assert_includes board, 'open: "cartOpen"',
                    "the same cartOpen must drive the sidebar itself, or the cards would go mobile " \
                    "with no sidebar on screen"
  end

  test "the 1120px crossover still matches the sidebar it was derived from" do
    # content = min(vw, 1280) - 32 (max-w-7xl px-4) - 320 (the sidebar); a
    # four-up card is (content - 48)/4 and reaches 187px — the width the same
    # card gets 2-up on a 390px phone — at vw 1120. Both 320s below are inputs
    # to that number, so a sidebar that silently got wider moves the crossover.
    assert_match(/\.tm-sidebar-pushed \{ margin-right: 20rem; \}/, APP_CSS.read,
                 "the md push step is the 320px the crossover was solved for")
    assert_match(/width_class\s*=\s*local_assigns\.fetch\(:width_class, "w-80/, PANEL.read,
                 "the sidebar is 320px wide (w-80); widen it and 1120px is the wrong crossover")
    refute_match(/width_class:/, BOARD.read[/render "components\/sidebar_panel".*?aria_label/m].to_s,
                 "the picks sidebar must keep the default w-80 the crossover assumes")
  end
end
