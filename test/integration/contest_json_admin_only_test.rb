require "test_helper"

# PRIVACY: the "Contest JSON" debug block (studio-engine components/json_debug)
# serializes every entry's user {id, name}, on-chain signatures and payouts. On
# 2026-10-06 it rendered for signed-out visitors on /contests/<slug>/live. It is
# admin-only now (ContestsHelper#contest_debug_json_visible?). These requests
# pin every surface that draws it: the contest page (turf-totals board and
# leaderboard), the live board, the leaderboard poll JSON, and the
# world-cup-survivor board.
class ContestJsonAdminOnlyTest < ActionDispatch::IntegrationTest
  PRIVATE_NAME = "Privatia Realname-Quillfeather".freeze

  setup do
    @contest = contests(:one) # turf_totals, open, starts in 30 days
    @private_user = User.create!(name: PRIVATE_NAME, username: "privatia_#{SecureRandom.hex(3)}",
                                 email: "privatia-#{SecureRandom.hex(3)}@example.com")
    @contest.entries.create!(user: @private_user, status: :active, score: 2.0)

    @survivor = Contest.create!(name: "Survivor Privacy #{SecureRandom.hex(2)}",
                                game_type: :world_cup_survivor, contest_type: "survivor_wc_free",
                                status: "open", starts_at: 1.hour.ago, rank: 8000 + rand(900))
    @survivor.entries.create!(user: @private_user, status: :active)

    @player = users(:jordan)
    @admin  = users(:alex)
    # Fixtures bypass Sluggable's set_slug; the impersonation route keys on it.
    [@admin, @player].each { |u| u.update_column(:slug, u.send(:name_slug)) }
  end

  # --- guest ---------------------------------------------------------------

  test "a guest sees no Contest JSON on the turf-totals contest page" do
    get contest_path(@contest) # bare show: not started, so it renders rather than routing to live
    assert_response :success
    assert_no_debug_block

    get contest_page_path(@contest)
    assert_response :success
    assert_no_debug_block
  end

  test "a guest sees no Contest JSON on the turf-totals live board" do
    get live_contest_path(@contest)
    assert_response :success
    assert_no_debug_block
  end

  test "a guest's leaderboard poll carries no Contest JSON" do
    get contest_leaderboard_poll_path(@contest, version: 0)
    assert_response :success
    html = JSON.parse(response.body).fetch("html")
    assert_not_includes html, "Contest JSON"
    assert_not_includes html, PRIVATE_NAME
  end

  test "a guest sees no Contest JSON on the world-cup-survivor contest page" do
    get contest_page_path(@survivor)
    assert_response :success
    assert_no_debug_block
  end

  # --- signed-in player ----------------------------------------------------

  test "a signed-in player sees no Contest JSON on the contest page, live board or survivor board" do
    log_in_as(@player)

    get contest_page_path(@contest)
    assert_response :success
    assert_no_debug_block

    get live_contest_path(@contest)
    assert_response :success
    assert_no_debug_block

    get contest_page_path(@survivor)
    assert_response :success
    assert_no_debug_block
  end

  # --- admin ---------------------------------------------------------------

  test "an admin sees the Contest JSON on the contest page, live board and survivor board" do
    log_in_as(@admin)

    get contest_page_path(@contest)
    assert_response :success
    assert_includes response.body, "Contest JSON"
    assert_includes response.body, PRIVATE_NAME, "the turf-totals block should serialize entry users for an admin"

    get live_contest_path(@contest)
    assert_response :success
    assert_includes response.body, "Contest JSON"
    assert_includes response.body, PRIVATE_NAME

    get contest_page_path(@survivor)
    assert_response :success
    assert_includes response.body, "Contest JSON"
  end

  # An admin acting as a player gets the player's page, exactly: the same
  # predicate as require_admin, which reads the impersonated current_user.
  test "an admin impersonating a player sees the player's page, without Contest JSON" do
    log_in_as(@admin)
    post admin_impersonate_path(@player.slug)
    assert_equal @player.id, session[:impersonated_user_id]

    get live_contest_path(@contest)
    assert_response :success
    assert_no_debug_block

    delete admin_stop_impersonating_path
    get live_contest_path(@contest)
    assert_includes response.body, "Contest JSON", "stopping impersonation restores the admin's debug block"
  end

  # A future contest view that renders the debug partial must gate it too.
  test "every contests view that renders components/json_debug gates it on contest_debug_json_visible?" do
    sites = Dir[Rails.root.join("app/views/contests/**/*.erb")].select { |f| File.read(f).include?("components/json_debug") }
    assert sites.any?, "expected at least one contests view to render the debug block"
    sites.each do |file|
      src = File.read(file)
      renders = src.scan(/render\s+"components\/json_debug"/).size
      gates   = src.scan(/<%\s*if contest_debug_json_visible\?\s*%>/).size
      assert_operator gates, :>=, renders, "#{file.sub("#{Rails.root}/", "")}: every json_debug render must sit inside `<% if contest_debug_json_visible? %>`"
    end
  end

  private

  def assert_no_debug_block
    assert_not_includes response.body, "Contest JSON"
    assert_not_includes response.body, "json-debug"
    assert_not_includes response.body, PRIVATE_NAME
  end
end
