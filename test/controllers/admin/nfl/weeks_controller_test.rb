require "test_helper"

# [integration] Admin::Nfl::WeeksController — the operator's focus order, end to
# end through the request.
#
# The page is ONE drag-ordered list covering the whole week, so there is exactly
# one write: the new order, POSTed as the studio/board primitive's
# `{ slugs: [...], zone: }`. Position is the rank.
class Admin::Nfl::WeeksControllerTest < ActionDispatch::IntegrationTest
  SLOT = "2026-2-4".freeze

  setup do
    @admin = users(:alex)
    @user  = users(:sam)

    Team.where(slug: %w[team-a team-b team-c team-d team-e team-f])
        .update_all(league: "nfl", sport: "football")

    @early = create_game("team-a", "team-b", Time.utc(2026, 9, 13, 17, 0))
    @late  = create_game("team-c", "team-d", Time.utc(2026, 9, 13, 20, 25))
    @night = create_game("team-e", "team-f", Time.utc(2026, 9, 14, 0, 20))
    # A game in a DIFFERENT week — the scope everything here is written against.
    @other_week = Game.create!(home_team_slug: "team-d", away_team_slug: "team-a",
                               season_year: 2026, season_type: 2, week: 5,
                               kickoff_at: Time.utc(2026, 9, 20, 17, 0))
  end

  def create_game(home, away, kickoff)
    Game.create!(home_team_slug: home, away_team_slug: away,
                 season_year: 2026, season_type: 2, week: 4, kickoff_at: kickoff)
  end

  def reorder(slugs, zone: "focus", slot: SLOT)
    post reorder_admin_nfl_week_path(slot), params: { slugs: slugs, zone: zone }, as: :json
  end

  def ranks
    Game.where(slug: [@early.slug, @late.slug, @night.slug]).pluck(:slug, :focus_rank).to_h
  end

  def week_slugs = [@early.slug, @late.slug, @night.slug]

  # ── ACCESS ───────────────────────────────────────────────────────────────

  test "the index turns away a signed-out reader" do
    get admin_nfl_weeks_path
    assert_response :redirect
  end

  test "the index turns away a signed-in non-admin" do
    log_in_as(@user)
    get admin_nfl_weeks_path
    assert_response :redirect
  end

  test "a non-admin cannot reorder a week" do
    log_in_as(@user)
    reorder([@night.slug, @late.slug, @early.slug])

    assert_response :redirect
    assert_nil @night.reload.focus_rank
  end

  # ── INDEX ────────────────────────────────────────────────────────────────

  test "the index lists every week we hold games for" do
    log_in_as(@admin)

    get admin_nfl_weeks_path

    assert_response :success
    assert_select "a[href=?]", admin_nfl_week_path(SLOT), text: /Week 4/
    assert_select "a[href=?]", admin_nfl_week_path("2026-2-5"), text: /Week 5/
  end

  # A week is either in an order someone dragged it into or in the kickoff order
  # it seeds with — nothing in between, because a reorder writes the whole list.
  test "the index says whether a week has been dragged out of kickoff order" do
    log_in_as(@admin)

    get admin_nfl_weeks_path
    assert_select "tr", text: /Week 4.*Kickoff/m

    reorder([@night.slug, @early.slug, @late.slug])
    get admin_nfl_weeks_path
    assert_select "tr", text: /Week 4.*Custom/m
  end

  # ── SHOW ─────────────────────────────────────────────────────────────────

  # THE UNTOUCHED LIST IS THE CURRENT BEHAVIOUR, drawn. With no ranks the ladder
  # falls back to kickoff order, so seeding the board that way means an operator
  # is looking at what the board already does rather than at an empty form.
  test "an undragged week lists its games in kickoff order" do
    log_in_as(@admin)

    get admin_nfl_week_path(SLOT)

    assert_response :success
    assert_equal week_slugs, css_select("#dropzone-focus .kanban-card").map { |el| el["data-slug"] }
  end

  # REGRESSION: `in_season_slot` carries its own `.order(:kickoff_at)`, so an
  # ordering scope that APPENDS leaves kickoff as the primary sort — the drag
  # saves correctly and is simply never rendered, which is indistinguishable
  # from a save that did not land.
  test "a dragged week lists its games in the order it was dragged into" do
    log_in_as(@admin)
    reorder([@night.slug, @early.slug, @late.slug])
    assert_response :success

    get admin_nfl_week_path(SLOT)

    assert_equal [@night.slug, @early.slug, @late.slug],
                 css_select("#dropzone-focus .kanban-card").map { |el| el["data-slug"] }
  end

  test "the list holds this week's games and no others" do
    log_in_as(@admin)

    get admin_nfl_week_path(SLOT)

    assert_select "#dropzone-focus .kanban-card", count: 3
    assert_select ".kanban-card[data-slug=?]", @other_week.slug, count: 0
  end

  test "the week page names the game the ladder is focusing right now" do
    log_in_as(@admin)

    get admin_nfl_week_path(SLOT)

    assert_select "[data-test=?]", "week-focus-now"
  end

  test "an id that is not a week goes back to the index rather than blowing up" do
    log_in_as(@admin)

    get admin_nfl_week_path("not-a-week")

    assert_redirected_to admin_nfl_weeks_path
  end

  # ── REORDER ──────────────────────────────────────────────────────────────

  test "the list's order is its ranking" do
    log_in_as(@admin)

    reorder([@night.slug, @early.slug, @late.slug])

    assert_response :success
    assert_equal({ @night.slug => 1, @early.slug => 2, @late.slug => 3 }, ranks)
  end

  # THE CASE THE TRANSACTION EXISTS FOR. Ranks are unique per week in the
  # database, so writing a new order one row at a time collides on the first
  # write — two games trading 1 and 2 is the smallest example.
  test "two games can trade places in one save" do
    log_in_as(@admin)
    reorder(week_slugs)

    reorder([@late.slug, @early.slug, @night.slug])

    assert_equal({ @late.slug => 1, @early.slug => 2, @night.slug => 3 }, ranks)
  end

  # A payload that is not the whole week came from a stale page. Writing it
  # would rank part of the week and silently blank the rest.
  test "refuses an order that is missing a game and changes nothing" do
    log_in_as(@admin)
    reorder(week_slugs)

    reorder([@late.slug, @early.slug])

    assert_response :unprocessable_entity
    assert_equal({ @early.slug => 1, @late.slug => 2, @night.slug => 3 }, ranks)
  end

  test "refuses an order carrying a game from another week" do
    log_in_as(@admin)

    reorder(week_slugs + [@other_week.slug])

    assert_response :unprocessable_entity
    assert_nil @other_week.reload.focus_rank
    assert_nil @early.reload.focus_rank
  end

  # Same games, same set — but one of them twice. The set comparison alone would
  # wave this through and leave position 1 unused.
  test "refuses an order that names the same game twice" do
    log_in_as(@admin)

    reorder([@early.slug, @early.slug, @late.slug])

    assert_response :unprocessable_entity
    assert_nil @early.reload.focus_rank
  end

  test "an unknown week is refused as JSON rather than redirected" do
    log_in_as(@admin)

    reorder(week_slugs, slot: "not-a-week")

    assert_response :not_found
  end

  # ── WHAT IT IS ALL FOR ───────────────────────────────────────────────────

  test "the saved order decides which game the live board opens on" do
    log_in_as(@admin)
    reorder([@late.slug, @early.slug, @night.slug])

    games = Game.nfl.in_season_slot(year: 2026, season_type: 2, week: 4)
    focus = Live::FocusGame.pick(games, now: Time.utc(2026, 9, 13, 21, 0))

    assert_equal @late.slug, focus.slug, "both games have kicked off, so the higher one leads"
  end

  # The seeded order and no order at all must pick the same game — that identity
  # is what makes an undragged week safe to leave alone.
  test "the kickoff-seeded order changes nothing about the board's choice" do
    now = Time.utc(2026, 9, 13, 21, 0)
    games = Game.nfl.in_season_slot(year: 2026, season_type: 2, week: 4)
    before = Live::FocusGame.pick(games, now: now)

    log_in_as(@admin)
    reorder(week_slugs)   # kickoff order, which is how the board renders it

    assert_equal before.slug, Live::FocusGame.pick(games.reload, now: now).slug
  end
end
