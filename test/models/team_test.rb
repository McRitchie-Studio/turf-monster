require "test_helper"

class TeamTest < ActiveSupport::TestCase
  test "belongs to home arena by slug" do
    team = teams(:team_a)

    assert_equal arenas(:test_stadium), team.home_arena
  end

  test "league scopes return teams by metadata" do
    assert_includes Team.nfl, teams(:team_a)
    assert_includes Team.football, teams(:team_a)
  end

  test "mascot removes location prefix" do
    team = Team.new(name: "Seattle Seahawks", location: "Seattle")

    assert_equal "Seahawks", team.mascot
  end

  test "stores mascot when it can be derived" do
    team = Team.create!(name: "Denver Broncos", location: "Denver")

    assert_equal "Broncos", team.reload[:mascot]
    assert_equal "Broncos", team.mascot
  end

  test "stores logo metadata explicitly" do
    team = Team.create!(
      name: "Denver Broncos",
      location: "Denver",
      logo_url: "https://example.com/broncos.png",
      logo_path: "/team-logos/denver-broncos.png",
      logo_source: "manual"
    )

    team.reload
    assert_equal "https://example.com/broncos.png", team.logo_url
    assert_equal "/team-logos/denver-broncos.png", team.logo_path
    assert_equal "manual", team.logo_source
  end

  test "color_disposition enum gives prefixed predicates" do
    assert Team.new(color_disposition: "dark").disposition_dark?
    assert Team.new(color_disposition: "light").disposition_light?
    refute Team.new(color_disposition: "dark").disposition_light?
  end

  test "#dark_alt falls back to the dark brand color without a curated alt" do
    assert_equal "#101820", Team.new(color_dark: "#101820", color_dark_alt: nil).dark_alt
    assert_equal "#101820", Team.new(color_dark: "#101820", color_dark_alt: "").dark_alt
  end

  test "#dark_alt swaps in the curated dark-family neutral" do
    assert_equal "#3E3C3B", Team.new(color_dark: "#101820", color_dark_alt: "#3E3C3B").dark_alt
  end

  test "#light_alt falls back to the light brand color without a curated alt" do
    assert_equal "#D3BC8D", Team.new(color_light: "#D3BC8D", color_light_alt: nil).light_alt
    assert_equal "#D3BC8D", Team.new(color_light: "#D3BC8D", color_light_alt: "").light_alt
  end

  test "#light_alt swaps in the curated light-family neutral" do
    assert_equal "#B0B7BC", Team.new(color_light: "#FFFFFF", color_light_alt: "#B0B7BC").light_alt
  end

  test "a dark-disposition team paints the dark color and mascots in the light one" do
    # Ravens: dark navy field, gold mascot.
    ravens = Team.new(color_dark: "#241773", color_light: "#9E7C0C", color_disposition: "dark")

    assert_equal "#241773", ravens.card_background
    assert_equal "#9E7C0C", ravens.card_mascot
  end

  test "a light-disposition team swaps field and mascot" do
    # Saints: gold field, near-black mascot — the light color becomes the field.
    saints = Team.new(color_dark: "#101820", color_light: "#D3BC8D", color_disposition: "light")

    assert_equal "#D3BC8D", saints.card_background
    assert_equal "#101820", saints.card_mascot
  end
end
