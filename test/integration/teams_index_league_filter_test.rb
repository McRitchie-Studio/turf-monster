require "test_helper"

# Component tier for the /teams league filter: the page is public
# (TeamsController skips auth), so a request spec exercises the real view.
class TeamsIndexLeagueFilterTest < ActionDispatch::IntegrationTest
  setup do
    Team.create!(name: "Filter Test Gridiron", slug: "filter-test-gridiron", short_name: "FTG", league: "nfl", sport: "football")
    Team.create!(name: "Filter Test Nation", slug: "filter-test-nation", short_name: "FTN", league: "fifa", sport: "soccer")
  end

  test "renders a league pill per league plus All" do
    get teams_path
    assert_response :success
    assert_select "button", text: "All"
    assert_select "button", text: /NFL/
    assert_select "button", text: /World Cup/
  end

  test "each card carries its league for exact-match filtering" do
    get teams_path
    assert_select "[data-team-card][data-league=?]", "nfl"
    assert_select "[data-team-card][data-league=?]", "fifa"
  end

  test "the filter is wired into the card-filter controller, with All pressed" do
    get teams_path
    assert_select '[data-controller="card-filter"][data-card-filter-selector-value="[data-team-card]"]' do
      assert_select 'button[data-card-filter-key-param="league"][data-card-filter-value-param="all"][aria-pressed="true"].btn-primary', text: "All"
      assert_select 'button[data-card-filter-key-param="league"][data-card-filter-value-param="nfl"][aria-pressed="false"].btn-outline'
    end
  end
end
