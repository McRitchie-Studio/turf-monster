require "test_helper"

# Component tier for the redesigned palette strip on /teams: each card wears its
# own field and lists its brand colors in four families (Dark · Alt · Light ·
# Grey) as click-to-copy swatches — no role emoji, just the upcased hex.
class TeamsPaletteTest < ActionDispatch::IntegrationTest
  test "a card lists its colors as click-to-copy swatches under family labels" do
    four = Team.create!(name: "Palette Four", slug: "palette-four", short_name: "PF4",
                        league: "nfl", sport: "football",
                        color_dark: "#123456", color_light: "#654321",
                        color_dark_alt: "#000000", color_light_alt: "#FEDCBA",
                        color_alt: "#ABCDEF")
    get teams_path
    assert_response :success

    # The card is on the page, wearing its own field.
    assert_select "a[href=?]", team_path(four)

    # The strip groups swatches under four family labels — no emoji.
    assert_select "span", text: "Dark"
    assert_select "span", text: "Alt"
    assert_select "span", text: "Light"
    assert_select "span", text: "Grey"

    # Each populated hex renders as a click-to-copy swatch (aria-labelled, upcased):
    # color_dark, color_light, color_dark_alt, color_light_alt, and color_alt.
    assert_select "button[aria-label=?]", "Copy #123456"
    assert_select "button[aria-label=?]", "Copy #654321"
    assert_select "button[aria-label=?]", "Copy #000000"
    assert_select "button[aria-label=?]", "Copy #FEDCBA"
    assert_select "button[aria-label=?]", "Copy #ABCDEF"
  end

  test "a card without an alt color renders no swatch for that missing hex" do
    Team.create!(name: "Palette Two", slug: "palette-two", short_name: "PF2",
                 league: "nfl", sport: "football",
                 color_dark: "#0B0B0B", color_light: "#FAFAFB")
    get teams_path
    # Its dark color still renders as a swatch...
    assert_select "button[aria-label=?]", "Copy #0B0B0B"
    # ...but the family labels are always present even when a family is empty.
    assert_select "span", text: "Alt"
  end

  test "every card shows a grey swatch, defaulting to the neutral grey" do
    Team.create!(name: "Palette Grey", slug: "palette-grey", short_name: "PGR",
                 league: "nfl", sport: "football",
                 color_dark: "#0A0A0A", color_light: "#FBFBFB")
    get teams_path
    # No team curates a grey, so the default neutral grey fills the Grey family.
    assert_select "button[aria-label=?]", "Copy #{TeamColorsHelper::DEFAULT_TEAM_GREY.upcase}"
  end

  test "the intro legend describes the palette families and drops the old emoji" do
    get teams_path
    assert_match "dark · light · alt · grey", response.body
    assert_match "click any swatch to copy its hex", response.body
    # The old role-emoji legend is gone.
    refute_match "🌒 dark", response.body
    refute_match "🌖 light", response.body
    refute_match "🔅 dark alt", response.body
    refute_match "🔆 light alt", response.body
  end
end
