require "test_helper"

class Admin::ModelsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:alex)
    @viewer = users(:jordan)
  end

  test "models overview requires admin" do
    get admin_models_path
    assert_response :redirect

    log_in_as @viewer
    get admin_models_path
    assert_response :redirect
  end

  test "admin sees the models page with links to all model pages" do
    log_in_as @admin
    get admin_models_path

    assert_response :success
    assert_select "h1", "Models"
    assert_select "table#models-users-table"
    assert_select "a[href=?]", admin_model_path("users")
    assert_select "a[href=?]", admin_model_path("teams")
    assert_select "a[href=?]", admin_model_path("arenas")
    assert_select "a[href=?]", admin_model_path("games")
    assert_match @admin.email, response.body
  end

  test "admin can browse users model page" do
    log_in_as @admin
    get admin_model_path("users")

    assert_response :success
    assert_select "table#models-users-table"
    assert_match @admin.email, response.body
  end

  test "admin can browse teams model page" do
    log_in_as @admin
    get admin_model_path("teams")

    assert_response :success
    assert_select "table#models-teams-table"
    assert_select "a[href*=?]", "sort=team"
    assert_select "a[href*=?]", "sort=sport"
    assert_select "a[href*=?]", "sort=league"
    assert_select "button[data-team-json-trigger=?]", "team-a"
    assert_match "Team A", response.body
    assert_match "Test Stadium", response.body
    assert_match "🏈", response.body
    assert_match /&quot;slug&quot;: &quot;team-a&quot;/, response.body
    assert_match /&quot;mascot&quot;: &quot;A&quot;/, response.body
    assert_match /&quot;logo_url&quot;: null/, response.body
    assert_match /&quot;home_arena&quot;/, response.body
    assert_match "not set", response.body
    assert_no_match "Sport / League", response.body
  end

  test "admin can sort teams by team sport and league" do
    log_in_as @admin

    get admin_model_path("teams", sort: "league", direction: "desc")
    assert_response :success
    assert_operator response.body.index("Team A"), :<, response.body.index("Team B")

    get admin_model_path("teams", sort: "sport", direction: "desc")
    assert_response :success
    assert_operator response.body.index("Team A"), :<, response.body.index("Team B")

    get admin_model_path("teams", sort: "team", direction: "desc")
    assert_response :success
    assert_operator response.body.index("Team F"), :<, response.body.index("Team A")
  end

  test "admin can browse arenas model page" do
    log_in_as @admin
    get admin_model_path("arenas")

    assert_response :success
    assert_select "table#models-arenas-table"
    assert_match "Test Stadium", response.body
    assert_match "1 Test Way", response.body
    assert_match "schedule-only", response.body
  end

  test "admin can browse games model page" do
    log_in_as @admin
    get admin_model_path("games")

    assert_response :success
    assert_select "table#models-games-table"
    assert_match "Team A", response.body
    assert_match "completed", response.body
  end

  test "model pages are paginated" do
    30.times do |index|
      Arena.create!(
        name: "Fixture Arena #{index.to_s.rjust(2, '0')}",
        address: "#{index} Test Way",
        location: "Test City, TS",
        country: "USA",
        timezone: "America/New_York"
      )
    end

    log_in_as @admin
    get admin_model_path("arenas", page: 2)

    assert_response :success
    assert_match "Page 2 of 2", response.body
    assert_select "a[href=?]", admin_model_path("arenas", page: 1), text: "Previous"
    assert_match "Fixture Arena", response.body
  end

  test "unknown model key returns not found" do
    log_in_as @admin
    get admin_model_path("contracts")

    assert_response :not_found
  end
end
