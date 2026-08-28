require "test_helper"

# [unit] TeamColorsHelper#team_glow_pair — the scoring ring's two colours.
#
# The ring says WHOSE score just landed, which needs two colours that are
# actually different. palette[:glow] could not always supply the second.
class TeamGlowPairTest < ActionView::TestCase
  include TeamColorsHelper

  test "a team that curates an alt colour keeps its own pair" do
    team = teams(:team_a)
    team.update!(color_light: "#9E7C0C", color_dark: "#241773", color_alt: "#C60C30")

    accent, second = team_glow_pair(team)
    assert_equal "#9e7c0c", accent.downcase
    assert_equal "#c60c30", second.downcase
  end

  # THE BUG THIS FIXES. palette[:glow] falls back `color_alt || color_light ||
  # mascot`, so a team with no alt returned its accent a second time and the ring
  # drew one flat hue. Measured: Baltimore reads gold-and-red, Washington and
  # Kansas City read yellow-and-yellow.
  test "a team with no alt falls back to its dark colour, not to itself" do
    team = teams(:team_b)
    team.update!(color_light: "#FFB612", color_dark: "#5A1414", color_alt: nil)

    accent, second = team_glow_pair(team)
    assert_equal "#ffb612", accent.downcase
    assert_equal "#5a1414", second.downcase
    assert_not_equal accent.downcase, second.downcase
  end

  test "the pair is never two of the same colour when a dark exists" do
    [%w[#FFB612 #5A1414], %w[#FFB81C #E31837], %w[#9E7C0C #241773]].each do |light, dark|
      team = teams(:team_b)
      team.update!(color_light: light, color_dark: dark, color_alt: nil)

      accent, second = team_glow_pair(team)
      assert_not_equal accent.to_s.downcase, second.to_s.downcase,
        "#{light}/#{dark} collapsed to one colour"
    end
  end

  test "a team with nothing to pair returns something rather than raising" do
    team = teams(:team_b)
    team.update!(color_light: "#FFB612", color_dark: nil, color_alt: nil)

    accent, second = team_glow_pair(team)
    assert accent.present?
    assert second.present?
  end
end
