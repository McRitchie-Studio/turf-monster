require "test_helper"

# [component] The week board's WIRING — the handful of strings that have to be
# exactly right for a drag to reach the server at all, and that no other test
# would notice going wrong.
#
# The board itself is studio-engine's (studio/board/board); what this app owns
# is the endpoint it POSTs to, the reorder-only shape it asks for, and the CSS
# counter that draws the position.
class AdminWeekBoardRenderTest < ActionDispatch::IntegrationTest
  SLOT = "2026-2-4".freeze

  setup do
    Team.where(slug: %w[team-a team-b team-c team-d]).update_all(league: "nfl", sport: "football")
    # Brand one team for real, Giants-shaped: the card is supposed to show the
    # MASCOT over the CITY in the team's own colours, and a fixture with neither
    # would let a plain-text card pass every assertion below.
    #
    # Branded BEFORE the games are created, and its slug re-read afterwards:
    # Team is Sluggable, so writing the name rewrites the slug — a game created
    # first would point at a slug that no longer exists.
    home = Team.find_by(slug: "team-a")
    home.update!(name: "New York Giants", location: "New York", mascot: nil,
                 color_dark: "#97233F", color_light: "#FFB612", color_disposition: "dark")
    @home_slug = home.reload.slug

    @first = Game.create!(home_team_slug: @home_slug, away_team_slug: "team-b",
                          season_year: 2026, season_type: 2, week: 4,
                          kickoff_at: Time.utc(2026, 9, 13, 17, 0))
    @second = Game.create!(home_team_slug: "team-c", away_team_slug: "team-d",
                           season_year: 2026, season_type: 2, week: 4,
                           kickoff_at: Time.utc(2026, 9, 13, 20, 25))
    log_in_as(users(:alex))
    get admin_nfl_week_path(SLOT)
  end

  def board_opts
    JSON.parse(css_select("[data-test='studio-board']").first["x-data"][/studioBoard\((.*)\)\z/m, 1])
  end

  # THE FACTORY, ONCE, AT PAGE LEVEL. A <script> inside the board component
  # template would be cloned by the component and never run, so the board would
  # render and simply not drag — silently, with no error anywhere.
  test "the studioBoard factory ships on the page" do
    assert_response :success
    assert_match(/window\.studioBoard\s*=/, response.body)
  end

  test "the reorder endpoint points at this week" do
    assert_equal reorder_admin_nfl_week_path(SLOT), board_opts["reorderUrl"]
    assert_equal "slugs", board_opts["reorderPayload"]
    assert_equal "slug", board_opts["idAttr"]
  end

  # REORDER ONLY. `group` false is what keeps a card inside the list — with a
  # group name the factory would allow a drag OUT of the only column, and the
  # drop would then try to PATCH a move endpoint that does not exist.
  test "the board is reorder-only, with nowhere to move a card to" do
    # false, not absent: the factory reads `opts.group === false` and omits
    # SortableJS's group entirely, which is what confines a drag to its zone.
    assert_equal false, board_opts["group"]
    assert_nil board_opts["moveUrl"]
    assert_nil board_opts["moveParam"]
  end

  test "the single column holds every game in the week" do
    assert_select "#dropzone-focus .kanban-card", count: 2
    assert_select "#dropzone-focus .kanban-card[data-slug=?][data-stage=?]", @first.slug, "focus"
    assert_select "#dropzone-focus .kanban-card[data-slug=?][data-stage=?]", @second.slug, "focus"
  end

  # THE CARD IS THE TILE /live DRAWS, not a plainer restatement of a game. An
  # operator ordering the week is choosing between the cards the board will
  # show, so the two renderings have to be the same one — and a card that
  # quietly fell back to short codes on a flat background would still satisfy
  # every structural assertion above.
  test "each card is the live board's own tile, in the teams' colours" do
    assert_select "#dropzone-focus .kanban-card [data-test=?]", "live-game-tile", count: 2

    assert_select "#dropzone-focus .kanban-card [data-team-slug=?]", @home_slug do |rows|
      assert_match(/--nfl-team:\s*#97233F/i, rows.first["style"].to_s,
                   "the row should carry the team's own field colour")
    end
    # Mascot over city, not an abbreviation.
    assert_select "#dropzone-focus .kanban-card", text: /Giants/
    assert_select "#dropzone-focus .kanban-card", text: /New York/
  end

  # SIDE BY SIDE, not stacked — the axis is the whole reason this board asks for
  # a size at all. A silent fall back to the stacked layout would double every
  # card's height and satisfy every other assertion here, so the tile names its
  # axis rather than leaving it to be inferred from utility classes.
  test "the two teams sit side by side to keep the list short" do
    assert_select "#dropzone-focus .kanban-card [data-role=?][data-layout=?]", "team-rows", "split",
                  count: 2
    assert_select "#dropzone-focus [data-role=?][data-layout=?]", "team-rows", "stack", count: 0
  end

  # THE POSITION IS DRAWN BY CSS. That is what keeps the number correct the
  # instant a drop finishes, with nothing re-rendered — so the rule is
  # load-bearing, not decoration, and its absence would leave every badge blank
  # rather than merely unstyled.
  test "the position badge is a counter over the list" do
    assert_match(/#dropzone-focus\s*\{\s*counter-reset:\s*focus-rank/, response.body)
    assert_match(/#dropzone-focus \.kanban-card\s*\{\s*counter-increment:\s*focus-rank/, response.body)
    assert_match(/content:\s*counter\(focus-rank\)/, response.body)
    assert_select "#dropzone-focus .kanban-card .tt-rank-badge"
  end
end
