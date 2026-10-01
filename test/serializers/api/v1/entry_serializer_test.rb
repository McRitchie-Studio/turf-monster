require "test_helper"

# [unit] Api::V1::EntrySerializer: the caller's own entry, and a leaderboard row.
class Api::V1::EntrySerializerTest < ActiveSupport::TestCase
  include AgentApiTestSupport

  setup do
    @contest = contests(:one)
    @sam = users(:sam)
    @entry = enter!(@sam, @contest, fixture_matchups)
  end

  def serializer(entry = @entry, viewer: @sam, writable: true)
    contest = Contest.includes(:slate).find(@contest.id)
    facts = Api::V1::ContestFacts.for([contest])
    entry = Entry.includes(:user, selections: { slate_matchup: :team }).find(entry.id)
    Api::V1::EntrySerializer.new(entry, contest: contest, facts: facts,
                                        board: Api::V1::Board.new(contest, contest_locked: facts.locked?(contest)),
                                        ranks: Api::V1::Ranking.for_contests([contest.id])[contest.id],
                                        web_rules: Api::V1::WebRules.new(viewer), viewer: viewer,
                                        writable: writable)
  end

  test "an own entry before lock: picks, provisional rank, no payout, editable" do
    data = serializer.as_json

    assert_equal @entry.slug, data[:slug]
    assert_equal "test-contest", data[:contest][:slug]
    assert_equal "open", data[:contest][:phase]
    assert_equal "active", data[:status]
    assert_equal true, data[:editable]
    assert_equal 0.0, data[:score]
    assert_equal 3, data[:rank], "the two fixture entries sit on 1.5, this one on 0"
    assert_nil data[:payout_cents]
    assert_equal false, data[:final]
    assert_equal "USD", data[:currency]
    assert_nil data[:tx_signature]
    assert_equal true, data[:picks_visible]
    assert_equal fixture_matchups.map(&:id), data[:picks].map { |pick| pick[:matchup_id] }
    assert_equal [nil], data[:picks].map { |pick| pick[:points] }.uniq
  end

  test "it reports the on-chain signature the entry was paid with" do
    @entry.update!(onchain_tx_signature: "5sig", entry_number: 0)

    assert_equal ["5sig", 0], serializer.as_json.values_at(:tx_signature, :entry_number)
  end

  # `editable` restates what Entry#update_picks! will accept. Hold the two together.
  test "editable is true exactly while update_picks! would accept an edit" do
    assert_equal true, serializer.as_json[:editable]
    assert_nothing_raised { @entry.update_picks!(fixture_matchups.map(&:id)) }

    @contest.update!(starts_at: 1.minute.ago)
    @entry.reload
    assert_equal false, serializer.as_json[:editable]
    assert_raises(RuntimeError) { @entry.update_picks!(fixture_matchups.map(&:id)) }
  end

  # PATCH /api/v1/entries/:slug refuses a caller who may not write, and a
  # cancelled contest (Api::V1::EntriesController#update_refusal).
  test "editable is false for a caller who may not write, and in a cancelled contest" do
    assert_equal true, serializer(writable: true).as_json[:editable]
    assert_equal false, serializer(writable: false).as_json[:editable]

    @contest.update!(onchain_cancelled: true)
    assert_equal false, serializer.as_json[:editable]
  end

  test "a complete entry in a settled contest is final: stored rank and payout, not editable" do
    @contest.update!(status: :settled)
    @entry.update!(status: :complete, rank: 2, payout_cents: 5000, score: 7.4)
    data = serializer.as_json

    assert_equal [2, 5000, true, false, 7.4], data.values_at(:rank, :payout_cents, :final, :editable, :score)
    assert_equal "settled", data[:contest][:phase]
  end

  test "a settled entry that won nothing reports a payout of zero, not null" do
    @contest.update!(status: :settled)
    @entry.update!(status: :complete, rank: 9, payout_cents: 0)

    assert_equal 0, serializer.as_json[:payout_cents]
  end

  test "a rival's leaderboard row hides its picks until the contest locks" do
    row = serializer(viewer: users(:jordan)).leaderboard_row

    assert_equal "sam_test", row[:display_name]
    assert_equal false, row[:mine]
    assert_nil row[:entry_slug]
    assert_equal false, row[:picks_visible]
    assert_nil row[:picks], "null, not an empty list: hidden is not the same as none"
    assert_equal 3, row[:rank]
  end

  test "the owner's leaderboard row shows its picks before lock" do
    row = serializer.leaderboard_row

    assert_equal true, row[:mine]
    assert_equal @entry.slug, row[:entry_slug]
    assert_equal 6, row[:picks].size
  end

  test "once the contest locks a rival's picks are visible" do
    @contest.update!(starts_at: 1.minute.ago)
    row = serializer(viewer: users(:jordan)).leaderboard_row

    assert_equal true, row[:picks_visible]
    assert_equal 6, row[:picks].size
    assert_equal [true], row[:picks].map { |pick| pick[:locked] }.uniq
  end

  test "an admin's key gets no admin bypass: rival picks stay hidden before lock" do
    row = serializer(viewer: users(:alex)).leaderboard_row

    assert users(:alex).admin?
    assert_equal false, row[:picks_visible]
  end
end
