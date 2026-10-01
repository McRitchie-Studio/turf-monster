require "test_helper"

# [unit] ApiEntryRequest: the fingerprint and the two clocks its states are read by.
class ApiEntryRequestTest < ActiveSupport::TestCase
  setup do
    @contest = contests(:one)
    @user = users(:sam)
  end

  def request(state:, attempted_at: Time.current, **attrs)
    ApiEntryRequest.create!({ user: @user, contest: @contest, idempotency_key: SecureRandom.uuid,
                              fingerprint: "f", state: state, attempted_at: attempted_at }.merge(attrs))
  end

  test "the fingerprint ignores pick order and separates contest, picks and allow_usdc" do
    base = ApiEntryRequest.fingerprint(contest: @contest, matchup_ids: [3, 1, 2], allow_usdc: false)

    assert_equal base, ApiEntryRequest.fingerprint(contest: @contest, matchup_ids: [1, 2, 3], allow_usdc: false)
    assert_equal base, ApiEntryRequest.fingerprint(contest: @contest, matchup_ids: %w[2 3 1], allow_usdc: nil)
    assert_not_equal base, ApiEntryRequest.fingerprint(contest: @contest, matchup_ids: [1, 2, 4], allow_usdc: false)
    assert_not_equal base, ApiEntryRequest.fingerprint(contest: @contest, matchup_ids: [1, 2, 3], allow_usdc: true)
    other = Contest.new(slug: "another")
    assert_not_equal base, ApiEntryRequest.fingerprint(contest: other, matchup_ids: [1, 2, 3], allow_usdc: false)
  end

  test "a key is unique per player, not globally" do
    first = request(state: "succeeded", idempotency_key: "k")

    assert_raises(ActiveRecord::RecordNotUnique) { request(state: "executing", idempotency_key: "k") }
    assert request(state: "executing", idempotency_key: "k", user: users(:jordan)).persisted?
    assert first.persisted?
  end

  test "a key must be printable with no spaces, 1 to 255 characters" do
    ["", " ", "a b", "tab\tbed", "x" * 256, "newline\n"].each do |bad|
      assert_not ApiEntryRequest.new(idempotency_key: bad).tap(&:valid?).errors[:idempotency_key].empty?, bad.inspect
    end
    ["a", "x" * 255, "550e8400-e29b-41d4-a716-446655440000", "entry:42/try#1"].each do |good|
      assert_empty ApiEntryRequest.new(idempotency_key: good).tap(&:valid?).errors[:idempotency_key], good
    end
  end

  test "executing is in flight until the timeout, then unsettled until the window closes" do
    row = request(state: "executing")

    assert row.in_flight?
    assert_not row.unsettled?
    assert_nil row.settles_at

    travel ApiEntryRequest::IN_FLIGHT_TIMEOUT + 1.second do
      assert_not row.in_flight?
      assert row.unsettled?
      assert_equal row.attempted_at + ApiEntryRequest::IN_FLIGHT_TIMEOUT, row.uncertain_since
      assert_equal row.attempted_at + ApiEntryRequest::IN_FLIGHT_TIMEOUT + ApiEntryRequest::SETTLE_WINDOW, row.settles_at
    end
  end

  test "uncertain is unsettled from the moment it was marked" do
    marked = 10.seconds.ago.change(usec: 0)
    row = request(state: "uncertain", spend_uncertain_at: marked)

    assert row.unsettled?
    assert_equal marked, row.uncertain_since
    assert_equal marked + ApiEntryRequest::SETTLE_WINDOW, row.settles_at
  end

  test "failed, confirming and succeeded have no spend outstanding" do
    %w[failed confirming succeeded].each do |state|
      row = request(state: state, attempted_at: 1.hour.ago)
      assert_not row.unsettled?, state
      assert_not row.in_flight?, state
    end
  end

  test "the settle window outlasts a blockhash, and the in-flight timeout outlasts a confirmation wait" do
    assert_operator ApiEntryRequest::SETTLE_WINDOW, :>=, 120.seconds
    assert_operator ApiEntryRequest::IN_FLIGHT_TIMEOUT, :>, 60.seconds
  end
end
