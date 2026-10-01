require "test_helper"

# [integration] GET /api/v1/entries and /entries/:slug: the caller's own
# confirmed entries, and nobody else's.
class Api::V1::EntriesControllerTest < ActionDispatch::IntegrationTest
  include AgentApiTestSupport

  setup do
    @contest = contests(:one)
    @user = users(:sam)
    @key = mint_api_key(@user)
    @entry = enter!(@user, @contest, fixture_matchups)
  end

  def slugs
    json["entries"].map { |entry| entry["slug"] }
  end

  test "both routes answer 401 in the envelope without a key" do
    [api_v1_entries_path, api_v1_entry_path(@entry.slug)].each do |path|
      api_get path, key: nil
      assert_api_error :unauthorized, "missing_api_key"
    end
  end

  test "the list returns the caller's confirmed entries with picks, score, rank and payout" do
    api_get api_v1_entries_path

    assert_response :success
    assert_equal [@entry.slug], slugs
    assert_equal({ "limit" => 25, "offset" => 0, "total" => 1, "has_more" => false }, json["pagination"])

    entry = json["entries"].first
    assert_equal %w[contest currency editable entry_number final payout_cents picks picks_visible rank score slug
                    status submitted_at tx_signature], entry.keys.sort
    assert_equal %w[cancelled game_type live locked locks_at name phase settled slug], entry["contest"].keys.sort
    assert_equal ["active", true, 3, 0.0, nil, false], entry.values_at("status", "editable", "rank", "score", "payout_cents", "final")
    assert_equal fixture_matchups.map(&:id), entry["picks"].map { |pick| pick["matchup_id"] }
    assert_equal %w[bye_weeks expected_team_score games games_count locked matchup_id points rank team team_score
                    turf_score], entry["picks"].first.keys.sort
  end

  test "another player's entries are never in the list" do
    api_get api_v1_entries_path

    assert_equal 3, @contest.entries.confirmed.count
    assert_equal 1, json["entries"].size
  end

  test "a cart and an abandoned entry are not served, in the list or by slug" do
    cart = Entry.create!(user: @user, contest: @contest, status: :cart)
    abandoned = Entry.create!(user: @user, contest: @contest, status: :abandoned)

    api_get api_v1_entries_path
    assert_equal [@entry.slug], slugs

    [cart, abandoned].each do |entry|
      api_get api_v1_entry_path(entry.slug)
      assert_api_error :not_found, "not_found"
    end
  end

  test "per-pick points and the entry score follow the results" do
    slate_matchups(:m2).update!(goals: 3) # x1.2
    @contest.score_entries!

    api_get api_v1_entry_path(@entry.slug)

    entry = json["entry"]
    pick = entry["picks"].find { |row| row["matchup_id"] == slate_matchups(:m2).id }
    assert_equal [3, 1.2, 3.6], pick.values_at("team_score", "turf_score", "points")
    assert_equal 3.6, entry["score"]
    assert_equal 1, entry["rank"], "the fixture entries have no picks and rescore to zero"
  end

  test "a settled entry reports its final rank, payout and signature, and is no longer editable" do
    @contest.update!(status: :settled)
    @entry.update!(status: :complete, rank: 1, payout_cents: 30_000, score: 12.5, onchain_tx_signature: "5sig")

    api_get api_v1_entry_path(@entry.slug)

    entry = json["entry"]
    assert_equal ["complete", 1, 30_000, true, false, 12.5, "5sig"],
                 entry.values_at("status", "rank", "payout_cents", "final", "editable", "score", "tx_signature")
    assert_equal ["settled", true], entry["contest"].values_at("phase", "settled")
  end

  test "an entry stops being editable when its contest locks" do
    @contest.update!(starts_at: 1.minute.ago)

    api_get api_v1_entry_path(@entry.slug)

    assert_equal false, json["entry"]["editable"]
    assert_equal [true], json["entry"]["picks"].map { |pick| pick["locked"] }.uniq
  end

  test "another player's entry slug is a 404, the same as a slug that does not exist" do
    rival = enter!(users(:jordan), @contest, fixture_matchups.reverse)

    api_get api_v1_entry_path(rival.slug)
    assert_api_error :not_found, "not_found"

    api_get api_v1_entry_path("no-such-entry")
    assert_api_error :not_found, "not_found"
  end

  test "contest narrows the list to one contest, and an unknown contest is a 404" do
    slate = Slate.create!(name: "Other #{SecureRandom.hex(3)}")
    other_matchup = SlateMatchup.create!(slate: slate, team_slug: "team-a", status: "pending", turf_score: 1.0, rank: 1)
    other = Contest.create!(name: "Other Contest", slate: slate, status: :open, starts_at: 2.days.from_now)
    other_entry = enter!(@user, other, [other_matchup])

    api_get api_v1_entries_path
    assert_equal [other_entry.slug, @entry.slug], slugs, "newest first"

    api_get api_v1_entries_path, params: { contest: other.slug }
    assert_equal [other_entry.slug], slugs
    assert_equal 1, json["pagination"]["total"]

    api_get api_v1_entries_path, params: { contest: "no-such-contest" }
    assert_api_error :not_found, "not_found"
  end

  test "the list pages" do
    second = enter!(@user, @contest, fixture_matchups.first(5) + [])

    api_get api_v1_entries_path, params: { limit: 1 }
    assert_equal [second.slug], slugs
    assert_equal [2, true], json["pagination"].values_at("total", "has_more")

    api_get api_v1_entries_path, params: { limit: 1, offset: 1 }
    assert_equal [@entry.slug], slugs
  end

  test "the list costs the same number of queries for one entry as for three in the same contest" do
    api_get api_v1_entries_path # warm
    one = count_queries { api_get api_v1_entries_path }
    enter!(@user, @contest, fixture_matchups.first(5))
    enter!(@user, @contest, fixture_matchups.last(5))
    three = count_queries { api_get api_v1_entries_path }

    assert_equal 3, json["entries"].size
    assert_equal one, three
  end
end
