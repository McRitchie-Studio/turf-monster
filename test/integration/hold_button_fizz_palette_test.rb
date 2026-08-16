require "test_helper"

# The board dresses the hold button's fizz in the picked teams' colors: each
# pick contributes its light and dark brand color, six picks filling the twelve
# --fizz-c-* slots the bubbles read. The mapping is client-side (picks change
# without a reload), so what a request CAN prove is the wiring — the palette
# data reaches the page, the getter that maps it exists, and both hold buttons
# bind it. The live re-dress on pick is the Playwright gap, same precedent as
# the hold-window race in wallet_topup_test.
class HoldButtonFizzPaletteTest < ActionDispatch::IntegrationTest
  test "board carries each team's light and dark color into the pick data" do
    get contest_path(contests(:one))
    assert_response :success

    assert_includes response.body, "colorLight:", "matchupData must carry the team's light color"
    assert_includes response.body, "colorDark:", "matchupData must carry the team's dark color"

    team = contests(:one).pickable_matchups.first.team
    pal = ActionController::Base.helpers.extend(TeamColorsHelper).team_card_palette(team)
    assert_includes response.body, pal[:fizz_light], "the real light hex must reach the page"
    assert_includes response.body, pal[:fizz_dark], "the real dark hex must reach the page"
  end

  test "both board hold buttons bind the live fizz palette" do
    get contest_path(contests(:one))
    assert_response :success

    assert_equal 2, response.body.scan(':style="fizzPalette"').size,
      "the desktop + mobile hold buttons both wear the picked teams"
    assert_includes response.body, "get fizzPalette()", "the board must map picks onto the slots"
    assert_includes response.body, "'--fizz-c-' + (i * 2 + 1)",
      "slot order is team 1 light, team 1 dark, team 2 light, …"
  end

  test "a team with no brand colors leaves its slots unbound rather than blank" do
    # Unbound slots fall back to the bubble's own candy hue in CSS, so a team
    # without brand colors can never paint an invisible (empty-string) bubble.
    naked = Team.new
    pal = ActionController::Base.helpers.extend(TeamColorsHelper).team_card_palette(naked)

    assert pal[:fizz_light].present?, "a colorless team still yields a light color"
    assert pal[:fizz_dark].present?, "a colorless team still yields a dark color"
  end
end
