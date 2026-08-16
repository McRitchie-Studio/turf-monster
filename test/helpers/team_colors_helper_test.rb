require "test_helper"

class TeamColorsHelperTest < ActionView::TestCase
  include TeamColorsHelper

  # Mirrors the Team color API the helper reads: brand hex keyed by intrinsic
  # lightness plus the disposition that decides which color is the FIELD.
  TeamDouble = Struct.new(:color_dark, :color_light, :color_dark_alt, :color_light_alt, :color_alt, :color_grey,
                          :color_disposition, keyword_init: true) do
    def disposition_light? = color_disposition.to_s == "light"
    def dark_alt  = color_dark_alt.presence || color_dark
    def light_alt = color_light_alt.presence || color_light
    def card_background = disposition_light? ? color_light : color_dark
    def card_mascot     = disposition_light? ? color_dark : color_light
  end

  def dark_team(**overrides)
    TeamDouble.new({ color_dark: "#241773", color_light: "#9e7c0c", color_disposition: "dark" }.merge(overrides))
  end

  def light_team(**overrides)
    # Saints: gold field (light color), near-black mascot (dark color).
    TeamDouble.new({ color_dark: "#101820", color_light: "#d3bc8d", color_disposition: "light" }.merge(overrides))
  end

  # --- normalize_hex ---

  test "normalize_hex accepts #-prefixed, bare, and short hex" do
    assert_equal "#241773", normalize_hex("#241773")
    assert_equal "#241773", normalize_hex("241773")
    assert_equal "#ffffff", normalize_hex("#FFF")
  end

  test "normalize_hex rejects garbage and blanks" do
    assert_nil normalize_hex(nil)
    assert_nil normalize_hex("")
    assert_nil normalize_hex("not-a-color")
    assert_nil normalize_hex("#12345")
  end

  # --- darken / lighten ---

  test "darken moves toward black and lighten toward white" do
    assert_equal "#000000", darken_hex("#808080", 1.0)
    assert_equal "#ffffff", lighten_hex("#808080", 1.0)
    # identity at amount 0
    assert_equal "#3366cc", darken_hex("#3366cc", 0.0)
  end

  # --- contrast ---

  test "contrast_ratio spans the full 1..21 range" do
    assert_in_delta 21.0, contrast_ratio("#000000", "#ffffff"), 0.05
    assert_in_delta 1.0, contrast_ratio("#123456", "#123456"), 0.001
  end

  # --- palette: the whole card contract ---

  test "dark team gets white foreground, a team gradient, and the light color as accent" do
    pal = team_card_palette(dark_team)
    assert_equal TeamColorsHelper::LIGHT_FG, pal[:fg]
    assert_includes pal[:gradient], "linear-gradient"
    assert_includes pal[:fg_soft], "rgba(255, 255, 255"
    assert_equal "#9e7c0c", pal[:accent], "accent is the mascot (light color) on a dark field"
  end

  test "light-forward team gets dark foreground and a dark accent" do
    pal = team_card_palette(light_team)
    assert_equal TeamColorsHelper::DARK_FG, pal[:fg]
    assert_equal "#101820", pal[:accent], "accent is the mascot (dark color) on a gold field"
    assert_includes pal[:fg_soft], "rgba(15, 18, 22"
  end

  test "location line rides the light-family alt on a dark field" do
    # Dark Ravens field → the city line uses the light-family alt (white here).
    pal = team_card_palette(dark_team(color_light_alt: "#ffffff"))
    assert_equal "#ffffff", pal[:location]
  end

  test "location line rides the dark-family alt on a light gold field" do
    # Gold Saints field → the city line uses the dark-family alt (near-black).
    pal = team_card_palette(light_team(color_dark_alt: "#101820"))
    assert_equal "#101820", pal[:location]
  end

  test "palette exposes exactly the keys the card and picks sidebar consume" do
    # The board cards, the cart rows, the compact pick chips, and the hold
    # button's fizz all read these keys — renaming one silently breaks a
    # consumer. Lock the contract.
    pal = team_card_palette(dark_team)
    assert_equal %i[gradient fg fg_soft fg_faint border divider accent location grey glow mascot_shadow
                    fizz_light fizz_dark fizz_alt].sort,
                 pal.keys.sort
  end

  test "fizz colors are the team's raw brand pair, not the card's swapped field" do
    # The card swaps background/mascot by disposition; the fizz wants the pair
    # as curated, so six picks read as twelve distinct team colors.
    pal = team_card_palette(light_team(color_light: "#d3bc8d", color_dark: "#101820"))
    assert_equal "#d3bc8d", pal[:fizz_light]
    assert_equal "#101820", pal[:fizz_dark]
  end

  # --- glow: the holographic hover/select tint ---

  test "glow rides the extra alt brand color when a team curates one" do
    # Ravens park their red in the alt slot → the glow uses it.
    pal = team_card_palette(dark_team(color_alt: "#c60c30"))
    assert_equal "#c60c30", pal[:glow]
  end

  test "glow falls back to the light color when there is no alt" do
    # No alt curated → the glow drops to the team's light brand color.
    pal = team_card_palette(dark_team)
    assert_equal "#9e7c0c", pal[:glow]
  end

  # --- grey: the OPPONENTS strip color ---

  test "grey defaults to the neutral opponents grey when a team curates none" do
    assert_equal TeamColorsHelper::DEFAULT_TEAM_GREY, team_card_palette(dark_team)[:grey]
  end

  test "grey uses the team's curated grey over the default" do
    pal = team_card_palette(dark_team(color_grey: "#123456"))
    assert_equal "#123456", pal[:grey]
  end

  # --- mascot_shadow: the legibility halo, now taking a single hex ---

  test "mascot_shadow gives a near-black mascot the white halo" do
    assert_includes mascot_shadow("#000000"), "rgba(255, 255, 255"
    # #101820 (Saints near-black) also clears NEAR_BLACK_LUMINANCE.
    assert_includes mascot_shadow("#101820"), "rgba(255, 255, 255"
  end

  test "mascot_shadow gives a colorful mascot the black halo" do
    # Bears orange is dark-ish but well above near-black → keeps the dark halo.
    assert_includes mascot_shadow("#c83803"), "rgba(0, 0, 0"
  end

  test "mascot_shadow returns none without a mascot color" do
    assert_equal "none", mascot_shadow(nil)
  end

  # --- opponent_label_color: the opponent chips on a team card ---

  test "opponent_label_color uses the opponent's light color on a dark host card" do
    # Dark host field → the opponent's LIGHT color reads on it.
    opponent = TeamDouble.new(color_dark: "#0b162a", color_light: "#c83803", color_disposition: "dark")
    assert_equal "#c83803", opponent_label_color(opponent, dark_team)
  end

  test "opponent_label_color drops to the opponent's dark color on a light gold host card" do
    # Saints card (gold field) hosting the Raiders: use Vegas' DARK color (black),
    # since a light accent would wash out on the gold gradient.
    opponent = TeamDouble.new(color_dark: "#000000", color_light: "#a5acaf", color_disposition: "dark")
    assert_equal "#000000", opponent_label_color(opponent, light_team)
  end

  test "opponent_label_color is nil for a bye week" do
    assert_nil opponent_label_color(nil, dark_team)
  end

  test "palette survives a team with no brand colors" do
    pal = team_card_palette(TeamDouble.new(color_disposition: "dark"))
    assert_includes pal[:gradient], "linear-gradient"
    assert_equal TeamColorsHelper::LIGHT_FG, pal[:fg]
    assert_match(/\A#[0-9a-f]{6}\z/, pal[:accent])
  end
end
