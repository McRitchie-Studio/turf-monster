require "test_helper"

# [component] THE FOCUS GAME on /live, as it actually renders.
#
# The page draws every game TWICE — once as a hidden hero tile in the focus
# panel, once as a card in the grid — and then hides one of each so that every
# game appears on screen exactly once. These tests hold that invariant, because
# the two halves are hidden by two different rules in two different partials
# and nothing else would notice them drifting apart.
class LiveFocusRenderTest < ActionDispatch::IntegrationTest
  setup do
    Team.where(slug: %w[team-a team-b team-c team-d]).update_all(league: "nfl", sport: "football")

    # One week, three games: one being played, two still to come. The ladder
    # opens on the live one.
    @live = Game.create!(home_team_slug: "team-a", away_team_slug: "team-b",
                         season_year: 2026, season_type: 2, week: 4,
                         status: "in_progress", status_detail: "Q2 4:11",
                         kickoff_at: 1.hour.ago)
    @next_up = Game.create!(home_team_slug: "team-c", away_team_slug: "team-d",
                            season_year: 2026, season_type: 2, week: 4,
                            status: "scheduled", kickoff_at: 3.hours.from_now)
    @later = Game.create!(home_team_slug: "team-d", away_team_slug: "team-a",
                          season_year: 2026, season_type: 2, week: 4,
                          status: "scheduled", kickoff_at: 2.days.from_now)
  end

  def visible(selector)
    css_select(selector).reject { |el| el["style"].to_s.include?("display: none") }
  end

  # Alpine boots after first paint, so x-show alone is too late: without the
  # inline display:none the page would open as a column of hero tiles that then
  # collapses to one.
  test "renders every game into the focus panel with exactly one visible" do
    get live_path

    assert_response :success
    assert_select "[data-test=?]", "live-focus-game", count: 3
    assert_equal 1, visible("[data-test='live-focus-game']").size
  end

  test "opens on the game being played" do
    get live_path

    assert_equal @live.slug, visible("[data-test='live-focus-game']").first["data-focus-slug"]
    assert_select "[x-data=?]", "nflLiveBoard('#{@live.slug}')"
  end

  # THE DIFFERENCE FROM THE CONTEST BOARD. There the strip is a chooser and
  # keeps every chip; here the grid IS the list of games, so the one in the
  # hero panel is taken out of it.
  test "the focused game is not drawn in the grid" do
    get live_path

    assert_select "[data-test=?]", "live-grid-card", count: 3
    shown = visible("[data-test='live-grid-card']").map { |el| el["data-pick-slug"] }

    assert_equal 2, shown.size
    refute_includes shown, @live.slug, "the focused game should have left the grid"
    assert_includes shown, @next_up.slug
    assert_includes shown, @later.slug
  end

  # The invariant the two hiding rules exist to keep: one appearance per game.
  test "every game is on screen exactly once" do
    get live_path

    on_screen = visible("[data-test='live-focus-game']").map { |el| el["data-focus-slug"] } +
                visible("[data-test='live-grid-card']").map { |el| el["data-pick-slug"] }

    assert_equal [@live.slug, @next_up.slug, @later.slug].sort, on_screen.sort
  end

  test "every grid card presses through to the focus panel" do
    get live_path

    css_select("[data-test='live-grid-card']").each do |card|
      assert_equal "select('#{card["data-pick-slug"]}')", card["@click"]
    end
  end

  test "draws the focused game at hero size" do
    get live_path

    assert_select "[data-test='live-focus-game'] [data-role=score].text-5xl", minimum: 1
  end

  # The panel is what select() scrolls to, and the header is sticky — without a
  # scroll margin the game it just revealed lands underneath it. --nav-bottom is
  # the header's bottom EDGE; --nav-h is only its height, and the two differ
  # whenever an environment bar sits above the header.
  test "the focus panel reserves room for the sticky header when scrolled to" do
    get live_path

    assert_select "#nfl_live_focus" do |panels|
      assert_match(/scroll-margin-top:\s*calc\(var\(--nav-bottom/, panels.first["style"].to_s)
    end
  end

  # A score has to light the hero tile AND the grid card, which only works
  # while both carry the hooks the page's script queries for.
  test "hero tile and grid card share the animation hooks" do
    get live_path

    %w[live-focus-game live-grid-card].each do |marker|
      assert_select "[data-test='#{marker}'] [data-team-slug='team-a'] [data-role=score]",
                    { minimum: 1 }, "#{marker} should expose a score the scoring animation can find"
    end
  end

  # An empty week still has to render — no panel, and the grid's own empty card.
  test "a week with no games renders the empty board" do
    Game.where(season_year: 2026, season_type: 2, week: 4).destroy_all

    get live_path

    assert_response :success
    assert_select "[data-test=?]", "live-focus-game", count: 0
  end
end
