require "test_helper"

# Component tier for the redesigned multi-week team card: renders the real
# partial and asserts the new identity block (city over mascot, team gradient,
# accent mascot, light-forward flip) without depending on contest fixtures.
class MultiWeekTeamCardTest < ActionView::TestCase
  include ApplicationHelper
  include TeamColorsHelper

  MatchupDouble = Struct.new(:id, :team, :locked, keyword_init: true) do
    def locked? = locked
  end
  WeekMatchupDouble = Struct.new(:opponent_team, keyword_init: true)

  # Real (unsaved) Team so the card's palette helpers read the actual color API:
  # a dark-disposition Ravens by default (navy field, gold mascot).
  def team_double(**overrides)
    Team.new({
      name: "Baltimore Ravens", location: "Baltimore",
      emoji: "🐦‍⬛", short_name: "BAL",
      color_dark: "#241773", color_light: "#9e7c0c", color_disposition: "dark"
    }.merge(overrides))
  end

  def opponents_double
    [
      [1, WeekMatchupDouble.new(opponent_team: team_double(name: "Indianapolis Colts", emoji: "🐴", short_name: "IND"))],
      [2, nil], # bye
      [3, WeekMatchupDouble.new(opponent_team: team_double(name: "Dallas Cowboys", emoji: "⭐", short_name: "DAL"))]
    ]
  end

  def render_card(team, multiplier: 1.1)
    render(partial: "contests/multi_week_team_card",
           locals: { matchup: MatchupDouble.new(id: 42, team: team, locked: false),
                     multiplier: multiplier, opponents: opponents_double })
  end

  test "card splits city and mascot onto separate lines" do
    html = render_card(team_double)
    assert_includes html, "Baltimore"
    assert_includes html, "Ravens"
  end

  test "card drops the big team mascot emoji" do
    html = render_card(team_double)
    refute_includes html, "🐦‍⬛", "the header mascot emoji should be gone"
  end

  test "card paints a team-color gradient background" do
    html = render_card(team_double)
    assert_includes html, "linear-gradient"
  end

  test "mascot uses the accent color (a well-contrasting secondary)" do
    html = render_card(team_double)
    assert_match(/Ravens/, html)
    assert_includes html, "#9e7c0c", "mascot should render in the accent color"
  end

  test "dark team uses light foreground text" do
    html = render_card(team_double)
    assert_includes html, TeamColorsHelper::LIGHT_FG
  end

  test "light-forward team flips to dark foreground and a dark accent" do
    saints = team_double(name: "New Orleans Saints", location: "New Orleans",
                         emoji: "⚜️", short_name: "NO",
                         color_dark: "#101820", color_light: "#d3bc8d", color_disposition: "light")
    html = render_card(saints)
    assert_includes html, "New Orleans"
    assert_includes html, "Saints"
    assert_includes html, TeamColorsHelper::DARK_FG
    assert_includes html, "#101820"
    refute_includes html, "⚜️"
  end

  test "selection and lock wiring survive the restyle" do
    html = render_card(team_double)
    assert_includes html, "toggleSelection('42')"
    assert_includes html, "is-selected"
  end

  test "week opponents still render under the team" do
    html = render_card(team_double)
    assert_includes html, "IND"
    assert_includes html, "DAL"
    assert_includes html, "bye"
    assert_includes html, "Points"
  end

  # --- mobile opponent chips -------------------------------------------------
  # A mobile card is half a ~390px viewport, so each of the three opponent
  # columns is only ~45px wide. At text-sm the emoji plus a three-letter
  # abbreviation overflows that and `truncate` eats the short name down to one
  # letter ("I…"), which hides the very thing the row exists to show. These
  # assert the mobile size is smaller AND that md+ still gets the original.

  def fragment(html) = Nokogiri::HTML::DocumentFragment.parse(html)

  def classes_of(node)
    refute_nil node
    node["class"].to_s.split
  end

  def week_label(html, label)
    fragment(html).css("p").find { |p| p.text.strip == label }
  end

  def chip_span(html, text)
    fragment(html).css("span").find { |s| s.text.strip == text }
  end

  test "week label is a touch smaller on mobile and restores at lg" do
    classes = classes_of(week_label(render_card(team_double), "Week 1"))
    assert_includes classes, "text-[9px]", "mobile week label should shrink below 10px"
    assert_includes classes, "lg:text-[10px]", "the wide (lg) card keeps the original 10px label"
  end

  test "opponent abbreviation shrinks on mobile so a three-letter short name fits" do
    classes = classes_of(chip_span(render_card(team_double), "IND"))
    refute_includes classes, "text-sm",
                    "an unconditional text-sm truncates IND inside a ~48px mobile column"
    assert_includes classes, "text-[10px]"
    assert_includes classes, "lg:text-sm", "the wide (lg) card keeps the original size"
  end

  test "opponent emoji shrinks with its abbreviation on mobile" do
    classes = classes_of(chip_span(render_card(team_double), "\u{1F434}"))
    refute_includes classes, "text-sm"
    assert_includes classes, "text-[10px]"
    assert_includes classes, "lg:text-sm"
  end

  test "bye week keeps the same responsive sizing as a real opponent" do
    classes = classes_of(chip_span(render_card(team_double), "bye"))
    assert_includes classes, "text-[10px]"
    assert_includes classes, "lg:text-sm"
  end
end
