require "test_helper"

# [component] The MOBILE picks bar keeps its compact shape.
#
# Operator report (2026-08-26, iPhone Safari): the fixed bottom "Your Picks" bar
# ate roughly a quarter of the visible viewport. Two of its rows were pure
# overhead — a title line with nothing beside it, and a standalone "Clear n / 6"
# line under the grid — and the per-slot second line truncated so hard on a
# 393px screen that it cut off the MULTIPLIER ("vs ARI / LV / BUF x1.…"), which
# is the one number the pick is scored on.
#
# The fix folds Clear into the title row (the desktop sidebar already does this,
# see cart_actions_html) and lifts the multiplier onto the team-name line, where
# it is shrink-proof and the opponent list truncates instead.
#
# What this tier can prove: the server still renders that arrangement — Clear
# above the grid, multiplier outside the truncating line, a spacer that tracks
# the bar rather than a flat literal. What it cannot prove is the pixel height
# on a real phone; that is the operator's visual acceptance at the QA stop.
#
# It is worth having because every claim here is silently reversible. Moving the
# Clear button back under the grid, or dropping the multiplier back onto the
# opponent line, renders fine, tests green, and quietly gives the bar its rows
# back — on the one screen size that could not afford them.
class MobilePicksBarCompactTest < ActionDispatch::IntegrationTest
  setup do
    get contest_path(contests(:one))
    assert_response :success
    @html = response.body

    # The mobile bar only — the desktop sidebar carries a Clear chip of its own,
    # so an unsliced document cannot tell the two apart.
    start = @html.index('data-picks-bar="mobile"')
    assert start, "the contest page must render the mobile picks bar"
    @bar = @html[start..].split("<!-- JSON Debug Block -->").first
  end

  test "Clear sits in the header row, above the slot grid" do
    title = @bar.index("Your Picks")
    clear = @bar.index('aria-label="Clear all picks"')
    grid  = @bar.index("grid grid-cols-3")

    assert title && clear && grid, "expected a title, a Clear chip, and the slot grid"
    assert clear > title, "Clear belongs beside the title, not before it"
    assert clear < grid,
           "Clear moved back below the grid — that is the row the compact bar " \
           "was built to reclaim"
  end

  test "the mobile bar carries exactly one clear control" do
    assert_equal 1, @bar.scan("clearSelections()").length,
                 "a second clear control means the old standalone row came back"
  end

  test "the multiplier is not inside the truncating opponent line" do
    opponent_line = @bar[/<p[^>]*truncate[^>]*>vs <span x-text="selectionSlots\[i-1\]\.opName"><\/span><\/p>/]
    assert opponent_line,
           "expected the opponent list to be a line of its own that may truncate"
    refute_includes opponent_line, "turfScore",
                    "the multiplier is back on the truncating line, where a " \
                    "393px screen cuts it off"
  end

  test "the multiplier renders shrink-proof beside the team name" do
    assert_match(/shrink-0[^>]*x-text="'x' \+ selectionSlots\[i-1\]\.turfScore"/, @bar,
                 "without shrink-0 a long team name squeezes the multiplier out")
  end

  test "the scroll spacer tracks the bar instead of a flat height" do
    spacer = @html[/<div x-show="selectionCount > 0" class="md:hidden"[^>]*>/]
    assert spacer, "the mobile spacer must still render"
    assert_includes spacer, ":style=",
                    "a static height cannot cover both the compact bar and the " \
                    "taller Hold-to-Confirm state"
    assert_includes spacer, "selectionCount ===",
                    "the spacer height must key off the state that changes the " \
                    "bar's height — a full slate mounts the CTA"
  end

  test "the desktop sidebar keeps its own Clear chip" do
    assert_equal 2, @html.scan('aria-label="Clear all picks"').length,
                 "expected one Clear chip per cart — the desktop sidebar's and " \
                 "the mobile bar's; compacting mobile must not strip desktop"
  end
end
