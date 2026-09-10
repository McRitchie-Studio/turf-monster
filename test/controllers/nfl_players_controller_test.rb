require "test_helper"

# [integration] /nfl-players — the public browse surface over the seeded NFL
# player database.
#
# The page is deliberately three modes in one action, because the active league
# is ~2,900 players and rendering them all is not an option: no filter shows a
# team picker, ?team= shows that roster, ?position= shows that position across
# the league. Each mode is pinned here, along with the fact that the whole
# surface stays reachable signed-out.
class NflPlayersControllerTest < ActionDispatch::IntegrationTest
  test "index is public — no sign-in required" do
    get nfl_players_path
    assert_response :success
  end

  test "with no filter it renders the team picker, not every player" do
    get nfl_players_path
    assert_response :success

    # The picker links to a team-scoped roster; it must NOT be rendering
    # athlete cards, which is the whole point of the default mode.
    assert_select "a[href=?]", nfl_players_path(team: "team-a")
    assert_select "[data-athlete-card]", { count: 0 },
      "the unfiltered index must not render athlete cards — that is ~2,900 rows in production"
  end

  test "?team= renders only that team's roster" do
    get nfl_players_path(team: "team-a")
    assert_response :success

    assert_select "[data-athlete-card]", count: 2
    assert_select "[data-athlete-card][data-team=?]", "team-a", count: 2
    assert_select "[data-athlete-card][data-team=?]", "team-b", count: 0
  end

  test "a team roster is ordered by position, not by name" do
    get nfl_players_path(team: "team-a")

    positions = css_select("[data-athlete-card]").map { |el| el["data-position"] }
    assert_equal %w[QB LT], positions,
      "QB precedes LT in ORDERED_POSITIONS; alphabetical by last name would put Blocker first"
  end

  test "?position= spans teams" do
    get nfl_players_path(position: "QB")
    assert_response :success

    assert_select "[data-athlete-card]", count: 1
    assert_select "[data-athlete-card][data-position=?]", "QB"
  end

  test "position filter accepts a source spelling and normalizes it" do
    # "HB" is what some feeds call a running back; GENERAL_MAP folds it to RB.
    get nfl_players_path(position: "HB")
    assert_response :success
    assert_select "[data-athlete-card][data-position=?]", "RB", count: 1
  end

  test "a free agent is absent from the league-wide position view" do
    # `suffixed` has no team_slug. A position view is a league view, so a
    # player on no roster has no place in it.
    get nfl_players_path(position: "WR")
    assert_select "[data-athlete-card]", count: 0
  end

  test "show renders a player by their PERSON slug" do
    get nfl_player_path("pat-passer")
    assert_response :success

    assert_select "h1", text: "Pat Passer"
    assert_select "dd", text: %(6'5")
    assert_select "dd", text: "237 lbs"
    assert_select "dd", text: "Test State"
    assert_select "dd", text: "2018 · Rd 1 · Pk 7"
  end

  test "show is public" do
    get nfl_player_path("pat-passer")
    assert_response :success
  end

  test "show lists teammates and excludes the player themselves" do
    get nfl_player_path("pat-passer")

    slugs = css_select("[data-athlete-card]").map { |el| el["href"] }
    assert_includes slugs, nfl_player_path("baker-blocker")
    assert_not_includes slugs, nfl_player_path("pat-passer"),
      "a player is not their own teammate"
  end

  test "a player with no team shows no teammate list rather than the league" do
    get nfl_player_path("sam-suffix-jr")
    assert_response :success
    assert_select "[data-athlete-card]", count: 0
  end

  test "an unknown slug redirects instead of 500ing" do
    get nfl_player_path("nobody-at-all")
    assert_redirected_to nfl_players_path
  end

  test "the athlete slug is not the show param" do
    # to_param on Athlete returns "pat-passer-athlete" via Sluggable. The route
    # deliberately takes the person slug so the URL reads as the player's name;
    # if someone swaps the lookup to `find_by(slug:)` this goes red.
    get nfl_player_path("pat-passer-athlete")
    assert_redirected_to nfl_players_path
  end
end
