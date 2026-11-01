require "test_helper"

# Operator::ContestOps: the hub's named contest operations (docs/OPERATOR_API.md).
class Operator::ContestOpsTest < ActiveSupport::TestCase
  setup do
    @contest = contests(:one)
    @contest.update!(status: :open, onchain_contest_id: "onchain_ops")
    @vault = FakeVault.new
    @ops = Operator::ContestOps.new(vault_factory: -> { @vault })
  end

  test "list reports state, entry counts and paid-entry counts" do
    entries(:one).update!(onchain_tx_signature: "sig-paid-1")

    row = @ops.list.find { |r| r["slug"] == @contest.slug }

    assert_equal "open", row["status"]
    assert_equal 2, row["entries"]
    assert_equal 1, row["paid_entries"]
    assert_equal false, row["cancelled"]
    assert_equal false, row["cancel_queued"]
    assert_equal true, row["onchain"]
  end

  test "list open scope leaves settled contests out; all includes them" do
    @contest.update!(status: :settled)

    assert_nil @ops.list(scope: "open").find { |r| r["slug"] == @contest.slug }
    assert @ops.list(scope: "all").find { |r| r["slug"] == @contest.slug }
  end

  test "list clamps the limit" do
    assert_operator @ops.list(limit: 500).size, :<=, Operator::ContestOps::LIST_LIMIT_MAX
  end

  test "cancel with no paid entries queues one PendingTransaction for a cosign and broadcasts nothing" do
    result = nil
    assert_difference -> { PendingTransaction.count }, 1 do
      result = @ops.cancel(slug: @contest.slug, requested_by: "Alex McRitchie (go in Slack)", request_ref: "proposal-7")
    end

    assert_equal "queued", result["state"]
    assert_equal 0, result["paid_entries"]
    assert_equal "/admin/pending_transactions", result["treasury_path"]
    pending = PendingTransaction.find(result["pending_transaction_id"])
    assert_equal "cancel_contest", pending.tx_type
    assert_equal "pending", pending.status
    assert_nil pending.tx_signature
    meta = pending.parsed_metadata
    assert_equal "operator", meta["source"]
    assert_equal "proposal-7", meta["request_ref"]
    assert_equal "Alex McRitchie (go in Slack)", meta["requested_by"]
    assert meta["creator"].present?
    assert_equal 1, @vault.cancel_calls.size
    assert_empty Array(@vault.broadcast_calls)
  end

  test "cancel refuses while paid entries have no refund-or-credit choice" do
    entries(:one).update!(onchain_tx_signature: "sig-paid-2")

    error = nil
    assert_no_difference -> { PendingTransaction.count } do
      error = assert_raises(Operator::ContestOps::Refused) { @ops.cancel(slug: @contest.slug) }
    end
    assert_equal "paid_entries_need_choice", error.code
    assert_match(/1 paid entry/, error.message)
    assert_empty @vault.cancel_calls
  end

  test "cancel with paid entries and a choice records the choice on the pending transaction" do
    entries(:one).update!(onchain_tx_signature: "sig-paid-3")

    result = @ops.cancel(slug: @contest.slug, paid_entries: "credit")

    assert_equal "credit", result["paid_entries_choice"]
    assert_equal 1, result["paid_entries"]
    assert_equal "credit", PendingTransaction.find(result["pending_transaction_id"]).parsed_metadata["paid_entries_choice"]
  end

  test "a second cancel returns the waiting one and queues nothing new" do
    first = @ops.cancel(slug: @contest.slug)

    second = nil
    assert_no_difference -> { PendingTransaction.count } do
      second = @ops.cancel(slug: @contest.slug)
    end
    assert_equal "already_queued", second["state"]
    assert_equal first["pending_transaction_id"], second["pending_transaction_id"]
    assert_equal 1, @vault.cancel_calls.size
  end

  test "cancel refuses an unknown choice, an unknown contest, a settled one and a cancelled one" do
    assert_equal "bad_choice", assert_raises(Operator::ContestOps::Refused) { @ops.cancel(slug: @contest.slug, paid_entries: "both") }.code
    assert_equal "not_found", assert_raises(Operator::ContestOps::Refused) { @ops.cancel(slug: "nope") }.code
    @contest.update!(status: :settled)
    assert_equal "not_cancellable", assert_raises(Operator::ContestOps::Refused) { @ops.cancel(slug: @contest.slug) }.code
    @contest.update!(status: :open, onchain_cancelled: true)
    assert_equal "not_cancellable", assert_raises(Operator::ContestOps::Refused) { @ops.cancel(slug: @contest.slug) }.code
    assert_empty @vault.cancel_calls
  end

  test "prepare returns the pre-filled create link and writes nothing" do
    %w[10 11 12].each { |w| Slate.create!(name: "NFL 2026 Week #{w}", week: w.to_i) }
    anchor = Slate.find_by!(name: "NFL 2026 Week 10")

    result = nil
    assert_no_difference ["Contest.count", "Slate.count", "PendingTransaction.count"] do
      result = @ops.prepare(week: 10, weeks: 3, contest_type: "medium")
    end

    assert_equal "ready", result["state"]
    assert_equal "Weeks 10-12", result["weeks"]
    assert_equal 2026, result["year"]
    path = URI.parse(result["path"])
    assert_equal "/contests/new", path.path
    query = Rack::Utils.parse_nested_query(path.query)
    assert_equal anchor.id.to_s, query["slate_id"]
    assert_equal "medium", query["contest_type"]
    assert_equal "3", query.dig("contest", "week_span")
    assert_equal Contest::FORMATS["medium"][:entry_fee_cents], result["entry_fee_cents"]
  end

  test "prepare refuses a span with a missing week, rather than a shorter one" do
    Slate.create!(name: "NFL 2026 Week 10", week: 10)
    Slate.create!(name: "NFL 2026 Week 12", week: 12)

    error = assert_raises(Operator::ContestOps::Refused) { @ops.prepare(week: 10, weeks: 3) }
    assert_equal "no_slate", error.code
    assert_match(/week 11/, error.message)
  end

  test "prepare bounds its params" do
    assert_equal "bad_week", assert_raises(Operator::ContestOps::Refused) { @ops.prepare(week: 40) }.code
    assert_equal "bad_weeks", assert_raises(Operator::ContestOps::Refused) { @ops.prepare(week: 10, weeks: 4) }.code
    assert_equal "bad_season", assert_raises(Operator::ContestOps::Refused) { @ops.prepare(week: 10, season: "post") }.code
    assert_equal "bad_format", assert_raises(Operator::ContestOps::Refused) { @ops.prepare(week: 10, contest_type: "huge") }.code
  end
end
