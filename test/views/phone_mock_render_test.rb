require "test_helper"

# [component] The two phone mockups on /turf-monster-v2, rendered on their own:
# with the real Team rows (brand colours from team_card_palette) and with none
# (the nil-safe neutral fallback). Return values, not #rendered, because
# ActionView::TestCase#rendered accumulates across calls.
class PhoneMockRenderTest < ActionView::TestCase
  helper TeamColorsHelper

  # The fixtures carry no NFL rows, so the one this test reads is made here,
  # with a real brand field and mascot colour for the palette to resolve.
  setup do
    Team.create!(name: "Baltimore Ravens", slug: "baltimore-ravens", mascot: "Ravens",
                 location: "Baltimore", short_name: "BAL", emoji: "🐦‍⬛", sport: "football",
                 league: "nfl", color_dark: "#241773", color_light: "#9E7C0C")
  end

  def teams
    Team.where(slug: TurfMonsterRules.team_slugs).index_by(&:slug)
  end

  def render_phone(screen, teams)
    render(layout: "pages/phone_frame") { render("pages/#{screen}", teams: teams) }
  end

  test "the pick board draws the six lineup cards inside an aria-hidden frame" do
    html = render_phone("phone_pick_board", teams)
    doc = Nokogiri::HTML.fragment(html)

    frame = doc.at_css('[data-test="phone-mock"]')
    assert_equal "true", frame["aria-hidden"]
    assert_equal TurfMonsterRules::LINEUP.size, doc.css('[data-test="phone-pick-board"] > .grid > div').size
    TurfMonsterRules::LINEUP.each do |example|
      assert_includes html, number_with_precision(example.turf_score, precision: 1)
    end
    refute_includes html, "%>", "no ERB comment may leak into the page"
  end

  test "with Team rows the cards wear the team's own palette" do
    team = teams.fetch("baltimore-ravens")
    html = render_phone("phone_pick_board", teams)
    assert_includes html, team_card_palette(team)[:gradient]
    assert_includes html, team.mascot
  end

  test "with no Team rows both phones still draw, from slugs and neutral colours" do
    board = render_phone("phone_pick_board", {})
    scoring = render_phone("phone_scoring", {})

    assert_includes board, "Arizona Cardinals"
    assert_includes board, team_card_palette(nil)[:gradient]
    assert_includes scoring, "Arizona Cardinals"
  end

  test "the scoring phone prints derived points and the lineup total" do
    html = render_phone("phone_scoring", teams)
    assert_includes html, number_with_precision(TurfMonsterRules.lineup_total, precision: 1)
    TurfMonsterRules::LINEUP.each do |example|
      assert_includes html, number_with_precision(example.entry_points, precision: 1)
    end
  end
end
