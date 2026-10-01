require "test_helper"

# [unit] Api::V1::ContestSerializer: one contest's JSON.
class Api::V1::ContestSerializerTest < ActiveSupport::TestCase
  include AgentApiTestSupport

  setup { @contest = contests(:one) }

  def serialize(entries_count: 2, my_entries_count: 0, viewer: users(:sam), writable: true)
    contest = Contest.includes(:slate).find(@contest.id)
    Api::V1::ContestSerializer.new(contest, facts: Api::V1::ContestFacts.for([contest]),
                                            web_rules: Api::V1::WebRules.new(viewer),
                                            entries_count: entries_count,
                                            my_entries_count: my_entries_count, writable: writable).as_json
  end

  test "an open contest: identity, phase, money in cents, capacity and limits" do
    data = serialize

    assert_equal "test-contest", data[:slug]
    assert_equal "Test Contest", data[:name]
    assert_equal "turf_totals", data[:game_type]
    assert_equal true, data[:supported]
    assert_equal "fifa", data[:sport]
    assert_equal "goals", data[:scoring_unit]
    assert_equal "open", data[:status]
    assert_equal "open", data[:phase]
    assert_equal [false, false, false, false, false],
                 data.values_at(:locked, :live, :settled, :cancelled, :coming_soon)
    assert_equal true, data[:accepting_entries]
    assert_equal @contest.starts_at.iso8601, data[:locks_at]
    assert_equal "USD", data[:currency]
    assert_equal 1900, data[:entry_fee_cents]
    assert_equal 50_000, data[:guaranteed_prize_cents]
    assert_equal({ rank: 1, payout_cents: 30_000 }, data[:payouts].first)
    assert_equal [1, 2, 3, 4, 5], data[:payouts].map { |row| row[:rank] }
    assert_equal 29, data[:max_entries]
    assert_equal 2, data[:entries_count]
    assert_equal 27, data[:spots_left]
    assert_equal 6, data[:picks_required]
    assert_equal 3, data[:max_entries_per_player]
    assert_equal 0, data[:my_entries_count]
    assert_equal false, data[:multi_week]
    assert_not data.key?(:note)
  end

  test "an NFL slate scores in points, and names its weeks" do
    @contest.update!(slate: Slate.create!(name: "NFL 2026 Weeks 1-3"))
    data = serialize

    assert_equal "nfl", data[:sport]
    assert_equal "points", data[:scoring_unit]
    assert_equal "Weeks 1-3", data[:weeks]
  end

  test "capacity falls back to the format when the contest sets none, as the web does" do
    @contest.update!(max_entries: nil, contest_type: "small")

    assert_equal 5, serialize[:max_entries]
    assert_equal 3, serialize[:spots_left]
  end

  test "a cancelled contest keeps status open and says cancelled, and takes no entries" do
    @contest.update!(onchain_cancelled: true)
    data = serialize

    assert_equal "open", data[:status]
    assert_equal true, data[:cancelled]
    assert_equal false, data[:accepting_entries]
  end

  test "accepting_entries is false when coming soon, full, locked, or at the player's limit" do
    @contest.update!(coming_soon: true)
    assert_equal [true, false], serialize.values_at(:coming_soon, :accepting_entries)
    @contest.update!(coming_soon: false)

    assert_equal false, serialize(entries_count: 29)[:accepting_entries]
    assert_equal 0, serialize(entries_count: 31)[:spots_left], "an over-filled field reads zero, never negative"
    assert_equal false, serialize(my_entries_count: 3)[:accepting_entries]
    assert_equal true, serialize(my_entries_count: 2)[:accepting_entries]

    @contest.update!(starts_at: 1.minute.ago)
    assert_equal false, serialize[:accepting_entries]
  end

  # POST /api/v1/contests/:slug/entries refuses an account on hold or not yet
  # age verified (ApiKeyAuthentication#write_refusal) and a survivor contest
  # (Entries::ApiSubmission). The field must not promise what the endpoint refuses.
  test "accepting_entries is false for a caller who may not write, and for a contest the API cannot enter" do
    assert_equal true, serialize(writable: true)[:accepting_entries]
    assert_equal false, serialize(writable: false)[:accepting_entries]

    @contest.update!(game_type: :world_cup_survivor)
    assert_equal [false, false], serialize.values_at(:supported, :accepting_entries)
  end

  test "a locked contest is live, a settled one is settled and not live" do
    @contest.update!(starts_at: 1.hour.ago)
    assert_equal ["live", true, true, false], serialize.values_at(:phase, :locked, :live, :settled)

    @contest.update!(status: :settled)
    assert_equal ["settled", true, false, true], serialize.values_at(:phase, :locked, :live, :settled)
  end

  test "a survivor contest is listed, marked unsupported, with a note" do
    @contest.update!(game_type: :world_cup_survivor, slate: nil)
    data = serialize

    assert_equal "world_cup_survivor", data[:game_type]
    assert_equal false, data[:supported]
    assert_equal Api::V1::ContestSerializer::SURVIVOR_NOTE, data[:note]
    assert_equal 0, data[:picks_required]
    assert_equal 1, data[:max_entries_per_player]
  end
end
