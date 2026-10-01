require "test_helper"

# [integration] GET /api/v1/contests, /contests/:slug and /contests/:slug/leaderboard:
# the response shapes, the web's visibility rules, and the query budget.
class Api::V1::ContestsControllerTest < ActionDispatch::IntegrationTest
  include SpanContestBuilder
  include AgentApiTestSupport

  setup do
    @contest = contests(:one)
    @user = users(:jordan)
    @key = mint_api_key(@user)
  end

  def extra_contest!(name, **attrs)
    slate = Slate.create!(name: "#{name} slate #{SecureRandom.hex(3)}")
    SlateMatchup.create!(slate: slate, team_slug: "team-a", opponent_team_slug: "team-b", status: "pending")
    Contest.create!({ name: name, slate: slate, status: :open, starts_at: 5.days.from_now }.merge(attrs))
  end

  def slugs
    json["contests"].map { |contest| contest["slug"] }
  end

  # --- authentication ------------------------------------------------------

  test "every route answers 401 in the envelope without a key" do
    [api_v1_contests_path, api_v1_contest_path("test-contest"),
     api_v1_contest_leaderboard_path("test-contest")].each do |path|
      api_get path, key: nil
      assert_api_error :unauthorized, "missing_api_key"
    end
  end

  test "a frozen account can still read" do
    @user.update_columns(frozen_at: Time.current, frozen_reason: "test")

    api_get api_v1_contests_path
    assert_response :success
    api_get api_v1_contest_path("test-contest")
    assert_response :success
  end

  # --- GET /contests ---------------------------------------------------------

  test "the list returns open and settled contests, newest first, and never a pending one" do
    settled = extra_contest!("Settled One", status: :settled)
    pending = extra_contest!("Pending One", status: :pending)

    api_get api_v1_contests_path

    assert_response :success
    assert_includes slugs, "test-contest"
    assert_includes slugs, settled.slug
    assert_not_includes slugs, pending.slug
    assert_equal settled.slug, slugs.first, "newest first"
    assert_equal({ "limit" => 25, "offset" => 0, "total" => 2, "has_more" => false }, json["pagination"])
  end

  test "a pending contest is not listed for an admin key either, as on the web's list" do
    pending = extra_contest!("Pending One", status: :pending)

    api_get api_v1_contests_path, key: mint_api_key(users(:alex))

    assert_not_includes slugs, pending.slug
  end

  test "a listed contest carries the fields an agent chooses by" do
    api_get api_v1_contests_path
    contest = json["contests"].find { |row| row["slug"] == "test-contest" }

    assert_equal %w[accepting_entries cancelled coming_soon concludes_at currency entries_count entry_fee_cents
                    game_type games_per_team guaranteed_prize_cents live locked locks_at max_entries
                    max_entries_per_player multi_week my_entries_count name payouts phase picks_required
                    scoring_unit settled slug sport spots_left status supported tagline weeks], contest.keys.sort
    assert_equal 2, contest["entries_count"]
    assert_equal 1, contest["my_entries_count"], "jordan holds one of the two fixture entries"
    assert_equal 1900, contest["entry_fee_cents"]
    assert_equal({ "rank" => 1, "payout_cents" => 30_000 }, contest["payouts"].first)
    assert_equal @contest.starts_at.utc.iso8601, contest["locks_at"]
  end

  test "a cancelled contest is listed and flagged" do
    @contest.update!(onchain_cancelled: true)

    api_get api_v1_contests_path
    contest = json["contests"].find { |row| row["slug"] == "test-contest" }

    assert_equal [true, "open", false], contest.values_at("cancelled", "status", "accepting_entries")
  end

  test "cart and abandoned entries count toward neither total" do
    Entry.create!(user: @user, contest: @contest, status: :cart)
    Entry.create!(user: users(:sam), contest: @contest, status: :abandoned)

    api_get api_v1_contests_path
    contest = json["contests"].find { |row| row["slug"] == "test-contest" }

    assert_equal [2, 1], contest.values_at("entries_count", "my_entries_count")
  end

  test "limit and offset page the list, and a limit over the maximum is clamped" do
    3.times { |i| extra_contest!("Extra #{i}", created_at: (i + 1).minutes.from_now) }

    api_get api_v1_contests_path, params: { limit: 2 }
    first_page = slugs
    assert_equal 2, first_page.size
    assert_equal({ "limit" => 2, "offset" => 0, "total" => 4, "has_more" => true }, json["pagination"])

    api_get api_v1_contests_path, params: { limit: 2, offset: 2 }
    assert_equal 2, slugs.size
    assert_empty first_page & slugs
    assert_equal false, json["pagination"]["has_more"]

    api_get api_v1_contests_path, params: { limit: 5000, offset: -3 }
    assert_equal [100, 0], json["pagination"].values_at("limit", "offset")
  end

  test "status narrows the list, and an unknown status is a 400 rather than an empty list" do
    settled = extra_contest!("Settled One", status: :settled)

    api_get api_v1_contests_path, params: { status: "settled" }
    assert_equal [settled.slug], slugs

    api_get api_v1_contests_path, params: { status: "open" }
    assert_equal ["test-contest"], slugs

    api_get api_v1_contests_path, params: { status: "pending" }
    assert_api_error :bad_request, "bad_request"
  end

  test "the list costs the same number of queries for one contest as for six" do
    api_get api_v1_contests_path # warm
    one = count_queries { api_get api_v1_contests_path }
    5.times { |i| extra_contest!("Extra #{i}", starts_at: nil) }
    six = count_queries { api_get api_v1_contests_path }

    assert_equal 6, json["contests"].size
    assert_operator six, :<=, one + 1, "only the first-kickoff lookup for contests with no starts_at may be added"
  end

  # --- GET /contests/:slug -----------------------------------------------------

  test "contest detail returns the contest and its pickable teams" do
    api_get api_v1_contest_path("test-contest")

    assert_response :success
    assert_equal %w[contest teams], json.keys
    assert_equal "test-contest", json["contest"]["slug"]
    assert_equal 6, json["contest"]["picks_required"]
    assert_equal fixture_matchups.map(&:id), json["teams"].map { |team| team["matchup_id"] }

    team = json["teams"].first
    assert_equal %w[bye_weeks expected_team_score games games_count locked matchup_id rank team team_score turf_score],
                 team.keys.sort
    assert_equal({ "slug" => "team-a", "name" => "Team A", "short_name" => "TMA" }, team["team"])
    assert_equal [1, 1.0, false], team.values_at("rank", "turf_score", "locked")
    assert_equal %w[final home kickoff_at opponent started status team_score week], team["games"].first.keys.sort
  end

  test "on a span contest only each team's first game is pickable, with every game listed under it" do
    build_span_contest!(@contest)

    api_get api_v1_contest_path("test-contest")

    assert_equal true, json["contest"]["multi_week"]
    assert_equal 2, json["contest"]["games_per_team"]
    assert_equal 6, json["teams"].size
    assert_equal @contest.reload.pickable_matchup_ids.sort, json["teams"].map { |team| team["matchup_id"] }.sort
    assert_equal [2], json["teams"].map { |team| team["games"].size }.uniq
    later_ids = @contest.matchups.where(week: 2).pluck(:id)
    assert_empty later_ids & json["teams"].map { |team| team["matchup_id"] }
  end

  test "a pending contest is a 404 to a player and readable by an admin key" do
    @contest.update!(status: :pending)

    api_get api_v1_contest_path("test-contest")
    assert_api_error :not_found, "not_found"
    api_get api_v1_contest_leaderboard_path("test-contest")
    assert_api_error :not_found, "not_found"

    api_get api_v1_contest_path("test-contest"), key: mint_api_key(users(:alex))
    assert_response :success
    assert_equal "pending", json["contest"]["status"]
    assert_equal false, json["contest"]["accepting_entries"]
  end

  test "an unknown slug is a 404 in the envelope" do
    api_get api_v1_contest_path("no-such-contest")

    assert_api_error :not_found, "not_found"
  end

  test "a trailing format is not a second spelling of the endpoint" do
    api_get "/api/v1/contests/test-contest.html"

    assert_response :not_found
  end

  test "a survivor contest is served with its game type, a note and no team rows" do
    @contest.update!(game_type: :world_cup_survivor, slate: nil)

    api_get api_v1_contest_path("test-contest")

    assert_response :success
    assert_equal [false, "world_cup_survivor"], json["contest"].values_at("supported", "game_type")
    assert json["contest"]["note"].present?
    assert_equal [], json["teams"]

    api_get api_v1_contest_leaderboard_path("test-contest")
    assert_response :success
    assert_equal [false, []], json.values_at("supported", "entries")
    assert json["note"].present?
  end

  # --- GET /contests/:slug/leaderboard -------------------------------------------

  test "before lock the leaderboard shows the caller's own picks and hides every rival's" do
    mine = enter!(@user, @contest, fixture_matchups)
    rival = enter!(users(:sam), @contest, fixture_matchups.reverse)

    api_get api_v1_contest_leaderboard_path("test-contest")

    assert_response :success
    assert_equal true, json["picks_hidden_until_lock"]
    rows = json["entries"]
    assert_equal 4, rows.size
    assert_equal %w[currency display_name entry_slug final mine payout_cents picks picks_visible rank score],
                 rows.first.keys.sort

    own = rows.find { |row| row["entry_slug"] == mine.slug }
    assert_equal [true, true, 6], [own["mine"], own["picks_visible"], own["picks"].size]

    rivals = rows.reject { |row| row["mine"] }
    assert_equal 2, rivals.size, "alex's fixture entry and sam's"
    assert_equal [false], rivals.map { |row| row["picks_visible"] }.uniq
    assert_equal [nil], rivals.map { |row| row["picks"] }.uniq
    assert_equal [nil], rivals.map { |row| row["entry_slug"] }.uniq
    assert_not_includes response.body, rival.slug
    assert_includes rivals.map { |row| row["display_name"] }, "sam_test"
  end

  test "after lock every entry's picks are visible" do
    enter!(users(:sam), @contest, fixture_matchups)
    @contest.update!(starts_at: 1.minute.ago)

    api_get api_v1_contest_leaderboard_path("test-contest")

    assert_equal false, json["picks_hidden_until_lock"]
    assert_equal "live", json["contest"]["phase"]
    sam = json["entries"].find { |row| row["display_name"] == "sam_test" }
    assert_equal [false, true, 6], [sam["mine"], sam["picks_visible"], sam["picks"].size]
  end

  test "an unsettled leaderboard ranks ties together, best score first, with no payout yet" do
    enter!(users(:sam), @contest, [], score: 9.0)
    enter!(users(:casey), @contest, [], score: 0.0)

    api_get api_v1_contest_leaderboard_path("test-contest")
    rows = json["entries"]

    assert_equal [9.0, 1.5, 1.5, 0.0], rows.map { |row| row["score"] }
    assert_equal [1, 2, 2, 4], rows.map { |row| row["rank"] }
    assert_equal [nil], rows.map { |row| row["payout_cents"] }.uniq
    assert_equal [false], rows.map { |row| row["final"] }.uniq
  end

  test "a settled leaderboard reports the ranks and payouts grading stored" do
    @contest.update!(starts_at: 1.hour.ago)
    slate_matchups(:m1).update!(goals: 2)
    enter!(users(:sam), @contest, [slate_matchups(:m1)])
    enter!(users(:casey), @contest, [slate_matchups(:m1)])
    @contest.grade!

    api_get api_v1_contest_leaderboard_path("test-contest")
    rows = json["entries"]

    assert_equal "settled", json["contest"]["phase"]
    assert_equal [1, 1, 3, 3], rows.map { |row| row["rank"] }
    assert_equal [true], rows.map { |row| row["final"] }.uniq
    # Two tied for first split first and second prize: (30000 + 5000) / 2.
    assert_equal [17_500, 17_500], rows.first(2).map { |row| row["payout_cents"] }
    # Two tied for third split third and fourth prize: (5000 + 5000) / 2.
    assert_equal [5000, 5000], rows.last(2).map { |row| row["payout_cents"] }
    assert_equal Entry.where(contest: @contest).order(:rank, :id).pluck(:payout_cents),
                 rows.map { |row| row["payout_cents"] }
  end

  test "the leaderboard pages, and ranks are the contest's, not the page's" do
    enter!(users(:sam), @contest, [], score: 9.0)

    api_get api_v1_contest_leaderboard_path("test-contest"), params: { limit: 1, offset: 1 }

    assert_equal [2], json["entries"].map { |row| row["rank"] }
    assert_equal({ "limit" => 1, "offset" => 1, "total" => 3, "has_more" => true }, json["pagination"])
  end

  test "the leaderboard costs the same number of queries for two entries as for eight" do
    @contest.update!(starts_at: 1.minute.ago)
    api_get api_v1_contest_leaderboard_path("test-contest") # warm
    few = count_queries { api_get api_v1_contest_leaderboard_path("test-contest") }

    2.times do
      %i[sam casey alex].each { |name| enter!(users(name), @contest, fixture_matchups) }
    end
    many = count_queries { api_get api_v1_contest_leaderboard_path("test-contest") }

    assert_equal 8, json["entries"].size
    assert_equal 6, json["entries"].last["picks"].size
    assert_operator many, :<=, few + 3, "selections, their matchups and their teams preload once each"
  end
end
