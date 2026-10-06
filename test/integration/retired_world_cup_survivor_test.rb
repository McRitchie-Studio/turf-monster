require "test_helper"

# World Cup survivor is retired. Three promises follow, and this file holds each:
#
#   1. Nothing runs it: FORMATS has no survivor format, Contest's game_type enum
#      has no survivor value, and no app or lib source names the format, its
#      models or its grading service.
#   2. Root is the contests lobby, and the old World Cup paths 301 there.
#   3. A contest the retired format wrote stays a readable closed record: its
#      page, poll and lobby card answer (the agent API's half is in
#      test/controllers/api/v1/contests_controller_test.rb), nothing 500s, and every
#      entry and grading door refuses it.
#
# The fixture contest is written the way the old code wrote one: game_type
# "world_cup_survivor", contest_type "survivor_wc_free", no slate. The update is
# raw SQL because the enum no longer accepts that value, which is the point.
class RetiredWorldCupSurvivorTest < ActionDispatch::IntegrationTest
  RETIRED_SPELLINGS = /world_cup_survivor|survivor_wc_|SurvivorRound|SurvivorPick|Survivor::|survivor_board|contests#world_cup/

  setup do
    @admin = users(:alex)
    @winner = users(:jordan)
    @runner_up = users(:sam)

    @retired = Contest.create!(name: "World Cup Survivor Record", slug: "world-cup-survivor-record",
                               entry_fee_cents: 0, max_entries: 59, status: "settled",
                               contest_type: "small", slate: slates(:one), user: @admin)
    Contest.where(id: @retired.id).update_all(
      "game_type = 'world_cup_survivor', contest_type = 'survivor_wc_free', slate_id = NULL"
    )
    @first = Entry.create!(contest: @retired, user: @winner, status: :complete, rank: 1, payout_cents: 200_00, score: 8)
    @second = Entry.create!(contest: @retired, user: @runner_up, status: :complete, rank: 2, payout_cents: 0, score: 5)
    @retired.reload
  end

  # --- 1. nothing runs it ---------------------------------------------------

  test "[unit] FORMATS has no survivor format and the game type enum has no survivor value" do
    assert_empty Contest::FORMATS.keys.grep(/survivor/)
    assert_equal({ "turf_totals" => "turf_totals" }, Contest.game_types)
  end

  test "[unit] grading never branches on survivor: no app or lib source names the format or its parts" do
    files = Dir[Rails.root.join("{app,lib}/**/*.{rb,erb,js,rake}")]
    assert_operator files.size, :>, 300, "the scan must read the app, not an empty glob"

    offenders = files.select { |path| File.read(path).match?(RETIRED_SPELLINGS) }
    assert_empty offenders.map { |path| path.delete_prefix("#{Rails.root}/") }
    assert_not Rails.root.join("app/services/survivor").exist?
  end

  test "[unit] a retired row reads as a retired format, with the payouts its entries were paid" do
    assert_nil @retired.game_type, "an unknown enum value reads as nil, not a crash"
    assert @retired.retired_format?
    assert_not contests(:one).retired_format?
    assert_equal({ 1 => 200_00 }, @retired.payouts)
    assert_equal 200_00, @retired.guaranteed_prize_cents
    assert_equal Contest::FORMATS.fetch("standard"), contests(:one).format_config
  end

  # --- 2. root is the lobby -------------------------------------------------

  test "[integration] root answers the contests lobby" do
    get root_path

    assert_response :success
    assert_equal "contests", @controller.controller_name
    assert_equal "index", @controller.action_name
    assert_select "h1", text: "Contests"
  end

  test "[integration] the legacy World Cup paths 301 to root" do
    %w[/world-cup /world_cup].each do |path|
      get path
      assert_response :moved_permanently, path
      assert_redirected_to "http://www.example.com/"
    end
  end

  test "the lobby hands a saved cart back to the contest page it names" do
    get root_path

    script = css_select("script").map(&:text).find { |js| js.include?("pendingContestEntry") }
    assert script, "the lobby must look for a saved cart, because sign-ins with no destination land here"
    assert_includes script, "'/contests/' + encodeURIComponent(parsed.contestSlug) + '/contest'"
    assert_includes script, "parsed.handedOff = true"
    assert_not_includes script, "removeItem", "the cart is left for the board to consume"
  end

  # --- 3. a retired contest stays readable -----------------------------------

  test "[integration] a retired survivor contest renders its read-only page and final standings" do
    [contest_path(@retired), contest_page_path(@retired)].each do |path|
      get path
      assert_response :success, path
      assert_select "[data-final-standings]", 1
      assert_includes response.body, @winner.display_name
      assert_includes response.body, @runner_up.display_name
      assert_includes response.body, "$200"
      assert_select "#board", 0, "a retired contest has no board"
    end
  end

  test "a retired contest reads for a signed-in entrant and for an admin" do
    log_in_as(@winner)
    get contest_page_path(@retired)
    assert_response :success
    assert_includes response.body, "(you)"

    log_in_as(@admin)
    get admin_contest_path(@retired)
    assert_response :success
    assert_select "[data-final-standings]", 1
  end

  test "an open retired contest renders standings, never a board, and the poll and live board answer" do
    Contest.where(id: @retired.id).update_all(status: "open")

    get contest_page_path(@retired)
    assert_response :success
    assert_select "[data-final-standings]", 1
    assert_select "#board", 0

    get contest_leaderboard_poll_path(@retired, version: 0)
    assert_response :success
    assert_includes JSON.parse(response.body)["html"], "data-final-standings"

    get live_contest_path(@retired)
    assert_redirected_to contest_path(@retired)
  end

  test "the lobby and My Contests list a retired contest without failing" do
    get contests_path
    assert_response :success
    assert_includes response.body, @retired.name

    log_in_as(@winner)
    get my_contests_path
    assert_response :success
  end

  test "the admin pages that list or edit contests read a retired one without failing" do
    log_in_as(@admin)

    [edit_contest_path(@retired), generator_contests_path, new_admin_landing_page_path,
     admin_dashboard_path, admin_entry_gifts_path, admin_landing_pages_path].each do |path|
      get path
      assert_response :success, path
    end
    get new_admin_landing_page_path
    assert_select "select#landing_page_contest_id option", text: /#{@retired.name} · Retired format/
  end

  test "every entry and grading door refuses a retired contest" do
    Contest.where(id: @retired.id).update_all(status: "open")
    log_in_as(@admin)

    %i[enter prepare_entry check_funding toggle_selection clear_picks].each do |action|
      post "/contests/#{@retired.slug}/#{action}", as: :json
      assert_response :unprocessable_entity, action
      assert_equal ContestsController::RETIRED_FORMAT_MESSAGE, JSON.parse(response.body)["error"], action
    end

    post grade_contest_path(@retired)
    assert_redirected_to contest_page_path(@retired)
    assert_equal ContestsController::RETIRED_FORMAT_MESSAGE, flash[:alert]
    assert_not @retired.reload.settled?, "grading must not run"
  end

  test "editing an entry on a retired contest refuses with a reason, not a 500" do
    Contest.where(id: @retired.id).update_all(status: "open")

    error = assert_raises(Entry::Refusal) { @first.reload.update_picks!([]) }
    assert_equal :unsupported_contest, error.code
  end
end
