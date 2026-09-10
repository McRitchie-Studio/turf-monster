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
    assert_includes response.body, "colorAlt:", "matchupData must carry the team's alt color"

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
    # Lively is the board's level, so each button carries the hover layer that
    # brings in the teams' light colors on top of the resting darks.
    assert_equal 2, response.body.scan("hold-stack fizz-lively").size,
      "both board buttons are lively"
    assert_equal 2, response.body.scan("hold-fizz hold-fizz-extra").size,
      "and each renders its hover layer"
    assert_includes response.body, "get fizzPalette()", "the board must map picks onto the slots"
    assert_includes response.body, "'--fizz-c-' + (i * 3 + 1)",
      "three slots per pick: light, dark, alt — one zone per pick"
  end

  test "a team with no brand colors leaves its slots unbound rather than blank" do
    # Unbound slots fall back to the bubble's own candy hue in CSS, so a team
    # without brand colors can never paint an invisible (empty-string) bubble.
    naked = Team.new
    pal = ActionController::Base.helpers.extend(TeamColorsHelper).team_card_palette(naked)

    assert pal[:fizz_light].present?, "a colorless team still yields a light color"
    assert pal[:fizz_dark].present?, "a colorless team still yields a dark color"
    assert pal[:fizz_alt].present?, "and an alt, so its third slot is never blank"
  end

  test "the alt color is the flourish: curated where a team has one, its dark otherwise" do
    helpers = ActionController::Base.helpers.extend(TeamColorsHelper)

    ravens = Team.new(color_light: "#9e7c0c", color_dark: "#241773", color_alt: "#c60c30")
    assert_equal "#c60c30", helpers.team_card_palette(ravens)[:fizz_alt], "the Ravens' red"

    bucs = Team.new(color_light: "#d50a0a", color_dark: "#3e3c3b", color_alt: "#ff7900")
    assert_equal "#ff7900", helpers.team_card_palette(bucs)[:fizz_alt], "the Buccaneers' orange"

    plain = Team.new(color_light: "#69be28", color_dark: "#002244")
    pal = helpers.team_card_palette(plain)
    assert_equal pal[:fizz_dark], pal[:fizz_alt],
      "a team with no alt falls back to its dark, so its zone stays on-brand"
  end
end
