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
    Team.create!(name: "San Francisco 49ers", slug: "san-francisco-49ers", mascot: "49ers",
                 location: "San Francisco", short_name: "SF", emoji: "⛏️", sport: "football",
                 league: "nfl", color_dark: "#AA0000", color_light: "#B3995D")
  end

  def teams
    Team.where(slug: TurfMonsterRules.team_slugs | TurfMonsterRules.showcase_team_slugs).index_by(&:slug)
  end

  def render_phone(screen, teams)
    render(layout: "pages/phone_frame") { render("pages/#{screen}", teams: teams) }
  end

  test "the pick board draws the six showcase cards inside an aria-hidden frame" do
    html = render_phone("phone_pick_board", teams)
    doc = Nokogiri::HTML.fragment(html)

    frame = doc.at_css('[data-test="phone-mock"]')
    assert_equal "true", frame["aria-hidden"]
    cards = doc.css('[data-test="phone-pick-board"] > .grid > div')
    assert_equal 6, cards.size
    TurfMonsterRules::SHOWCASE.each do |example|
      assert_includes html, number_with_precision(example.turf_score, precision: 1)
    end
    refute_includes html, "%>", "no ERB comment may leak into the page"
  end

  # The six Alex picked, in board order: Turf Score ascending, then rank.
  test "the showcase is the six recognizable teams, ordered as the board orders them" do
    assert_equal %w[san-francisco-49ers los-angeles-rams dallas-cowboys seattle-seahawks minnesota-vikings new-orleans-saints],
                 TurfMonsterRules::SHOWCASE.map(&:team_slug)
    pairs = TurfMonsterRules::SHOWCASE.map { |e| [e.turf_score, e.rank] }
    assert_equal pairs.sort, pairs
    assert_equal [1.0, 1.1, 1.1, 1.2, 1.6, 1.8], TurfMonsterRules::SHOWCASE.map(&:turf_score)
    TurfMonsterRules::SHOWCASE.each { |e| assert_equal 3, e.opponent_slugs.size, "#{e.team_slug} has no bye in Weeks 1-3" }
  end

  # THE BOARD'S LABEL ON THE PHONE, THE RULES PAGE'S LABEL ON THE RULES PAGE.
  # The real board card reads "1.1x Points"; v1's static card reads
  # "1.1x Turf Score". The phone opts in to the board's; v1 must not move.
  test "phone cards label the multiplier Points; the v1 card still says Turf Score" do
    doc = Nokogiri::HTML.fragment(render_phone("phone_pick_board", teams))
    labels = doc.css('[data-test="multiplier-label"]').map { |n| n.text.strip }
    assert_equal ["Points"] * 6, labels
    refute_includes doc.text, "Turf Score"
    assert_includes doc.text.gsub(/\s+/, " "), "1.1x Points"

    v1_card = render(partial: "pages/rules_team_card",
                     locals: { example: TurfMonsterRules::FEATURE, teams: teams, compact: true })
    assert_includes v1_card, "Turf Score"
    refute_includes v1_card, "Points"
    refute_includes v1_card, "multiplier-label", "v1's markup is unchanged"
  end

  test "the scoring phone carries no Turf Score label either" do
    refute_includes render_phone("phone_scoring", teams), "Turf Score"
  end

  test "with Team rows the cards wear the team's own palette" do
    team = teams.fetch("san-francisco-49ers")
    html = render_phone("phone_pick_board", teams)
    assert_includes html, team_card_palette(team)[:gradient]
    assert_includes html, team.mascot
  end

  # NO ELLIPSIS, EVER. Every opponent chip is the emoji plus a 2-3 letter
  # abbreviation, untruncated, with or without Team rows.
  test "opponent chips are short abbreviations that never truncate" do
    [teams, {}].each do |team_rows|
      doc = Nokogiri::HTML.fragment(render_phone("phone_pick_board", team_rows))
      chips = doc.css('[data-test="opponent-abbr"]')
      assert_equal 18, chips.size
      chips.each do |chip|
        assert_match(/\A[A-Z0-9]{2,3}\z/, chip.text.strip, "chip #{chip.text.inspect} must be a 2-3 letter abbreviation")
        refute_includes chip["class"], "truncate"
      end
    end
    doc = Nokogiri::HTML.fragment(render_phone("phone_pick_board", teams))
    assert_includes doc.css('[data-test="opponent-abbr"]').map { |c| c.text.strip }, "SF", "the Rams' Week 1 chip is the 49ers' abbreviation"
  end

  test "with no Team rows both phones still draw, from slugs and neutral colours" do
    board = render_phone("phone_pick_board", {})
    scoring = render_phone("phone_scoring", {})

    assert_includes board, "New Orleans Saints"
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
