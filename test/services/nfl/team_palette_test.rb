require "test_helper"

class Nfl::TeamPaletteTest < ActiveSupport::TestCase
  test "PALETTE covers all 32 teams with valid dark/light hex and a disposition" do
    assert_equal 32, Nfl::TeamPalette::PALETTE.size
    Nfl::TeamPalette::PALETTE.each do |abbr, colors|
      assert_match(/\A#[0-9A-F]{6}\z/, colors[:dark],  "#{abbr} dark")
      assert_match(/\A#[0-9A-F]{6}\z/, colors[:light], "#{abbr} light")
      assert_includes %w[dark light], colors[:disposition], "#{abbr} disposition"
    end
  end

  test "every NFL team rides its dark field" do
    Nfl::TeamPalette::PALETTE.each do |abbr, colors|
      assert_equal "dark", colors[:disposition], "#{abbr} disposition"
    end
  end

  test "attributes_for maps the palette onto the color columns" do
    # New Orleans: gold light color, near-black dark, dark-disposition (every NFL
    # team now rides its dark field).
    attrs = Nfl::TeamPalette.attributes_for("NO")
    assert_equal "#101820", attrs[:color_dark]
    assert_equal "#D3BC8D", attrs[:color_light]
    assert_equal "dark",    attrs[:color_disposition]
  end

  test "attributes_for surfaces the extra alt brand color when a team curates one" do
    # Ravens park red, Bucs orange, Giants red in the alt slot.
    assert_equal "#C60C30", Nfl::TeamPalette.attributes_for("BAL")[:color_alt]
    assert_equal "#FF7900", Nfl::TeamPalette.attributes_for("TB")[:color_alt]
    assert_equal "#A71930", Nfl::TeamPalette.attributes_for("NYG")[:color_alt]
  end

  test "attributes_for leaves color_grey nil while no team curates a grey" do
    Nfl::TeamPalette::PALETTE.each_key do |abbr|
      assert_nil Nfl::TeamPalette.attributes_for(abbr)[:color_grey], "#{abbr} grey"
    end
  end

  test "attributes_for collapses blank alt and grey slots to nil" do
    attrs = Nfl::TeamPalette.attributes_for("NYJ") # simple two-color team
    assert_equal "#125740", attrs[:color_dark]
    assert_equal "#FFFFFF", attrs[:color_light]
    assert_nil attrs[:color_dark_alt]
    assert_nil attrs[:color_light_alt]
    assert_nil attrs[:color_alt]
    assert_nil attrs[:color_grey]
    assert_equal "dark", attrs[:color_disposition]
  end

  test "apply! recolors NFL rows only, never a same-abbreviation non-NFL team" do
    nfl_bal = Team.create!(name: "Recolor Ravens", slug: "recolor-ravens", short_name: "BAL",
                           league: "nfl", sport: "football", color_light: "#000000")
    other_bal = Team.create!(name: "Balkan United", slug: "balkan-united", short_name: "BAL",
                             league: "fifa", sport: "soccer", color_light: "#000000")

    count = Nfl::TeamPalette.apply! # default scope = Team.nfl

    assert_equal 1, count, "only the NFL BAL row is recolored"
    assert_equal "#241773", nfl_bal.reload.color_dark,       "NFL Ravens navy field"
    assert_equal "#9E7C0C", nfl_bal.color_light,             "NFL Ravens gold mascot"
    assert_equal "#FFFFFF", nfl_bal.color_light_alt,         "white kept as light alt"
    assert_equal "#C60C30", nfl_bal.color_alt,               "red parked in the alt slot"
    assert_equal "#000000", other_bal.reload.color_light,    "non-NFL BAL is untouched"
  end

  test "apply! is atomic — a mid-run failure rolls back every recolor" do
    bal = Team.create!(name: "Atomic Ravens", slug: "atomic-ravens", short_name: "BAL",
                       league: "nfl", sport: "football", color_light: "#000000")
    Team.create!(name: "Atomic Niners", slug: "atomic-niners", short_name: "SF",
                 league: "nfl", sport: "football", color_light: "#000000")

    # BAL sorts before SF in PALETTE, so BAL is updated first; blow up on SF.
    boom = ->(abbr) { raise "boom" if abbr == "SF"; { color_light: "#111111" } }
    Nfl::TeamPalette.stub(:attributes_for, boom) do
      assert_raises(RuntimeError) { Nfl::TeamPalette.apply! }
    end

    assert_equal "#000000", bal.reload.color_light, "BAL's update rolled back with the failed run"
  end
end
