require "test_helper"

# [component] The athlete card partial, as it renders inside a real page.
#
# What this pins is the AVATAR CONTRACT, which is the reason the feature
# exists: a player whose headshot was cached shows the image, and a player
# whose headshot was never cached shows initials at the same size instead of a
# broken image or a collapsed row. Roughly 3% of the active league has no
# espn_id, so the fallback is a normal state, not an edge case.
class NflPlayerCardRenderTest < ActionDispatch::IntegrationTest
  test "a cached headshot renders as an img pointing at the S3 object" do
    get nfl_players_path(team: "team-a")
    assert_response :success

    card = css_select("[data-athlete-card][data-position='QB']").first
    assert card, "the QB card should render"

    img = card.css("img").first
    assert img, "an athlete with a cached headshot renders an <img>"
    assert_includes img["src"], "headshots/nfl/team-a/pat-passer/100.png",
      "the card asks for the 100w variant, not the 400w detail-page one"
  end

  test "headshots are lazy-loaded and sized" do
    # A roster is ~90 cards; without loading=lazy and intrinsic dimensions the
    # page fetches every avatar up front and reflows as they land.
    get nfl_players_path(team: "team-a")

    img = css_select("[data-athlete-card][data-position='QB'] img").first
    assert_equal "lazy", img["loading"]
    assert_equal "48", img["width"]
    assert_equal "48", img["height"]
  end

  test "no cached headshot falls back to initials, not a broken image" do
    get nfl_players_path(position: "RB")
    assert_response :success

    card = css_select("[data-athlete-card]").first
    assert_empty card.css("img"), "an athlete with no cached headshot must not render an <img>"
    assert_includes card.text, "RR", "initials stand in for Rhea Rusher"
  end

  test "the card carries the filter attributes cardListFilter reads" do
    get nfl_players_path(team: "team-a")

    card = css_select("[data-athlete-card][data-position='QB']").first
    assert_equal "team-a", card["data-team"]
    assert_equal "QB", card["data-position"]
    # data-name is what the search box matches on — it must carry the player's
    # name AND their team, so "bills" finds a Bill.
    assert_includes card["data-name"], "pat passer"
    assert_includes card["data-name"], "team a"
  end

  test "each card links to that player's detail page" do
    get nfl_players_path(team: "team-a")

    card = css_select("[data-athlete-card][data-position='QB']").first
    assert_equal nfl_player_path("pat-passer"), card["href"]
  end

  test "the detail page asks for the larger headshot variant" do
    get nfl_player_path("pat-passer")

    # Scoped to the header card so a teammate's 100w avatar cannot satisfy this.
    img = css_select("img.w-40").first
    assert img, "the detail page renders a large headshot"
    assert_includes img["src"], "/400.png"
  end

  test "the team page shows the seeded roster alongside the existing player list" do
    get team_path(teams(:team_a))
    assert_response :success

    assert_select "[data-athlete-card]", count: 2
    assert_select "a[href=?]", nfl_players_path(team: "team-a")
  end
end
