require "test_helper"
require "rake"

# contests:reshape_payout through the rake task, against real rows.
class ContestsReshapePayoutTest < ActiveSupport::TestCase
  NINE_RANKS = ([1000_00] + [100_00] * 8).freeze
  FOUR_RANKS = [1000_00, 400_00, 200_00, 200_00].freeze
  WRITE_SQL = /\A\s*(INSERT|UPDATE|DELETE)\b/i

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("contests:reshape_payout")
    @contest = make_contest!(NINE_RANKS)
    @sibling = make_contest!(NINE_RANKS)
  end

  teardown { %w[WRITE TABLE_CENTS].each { |key| ENV.delete(key) } }

  def make_contest!(table, status: "open")
    contest = Contest.create!(name: "Reshape #{SecureRandom.hex(3)}", slate: slates(:one), contest_type: "large",
                              user: users(:alex), status: status, starts_at: 2.days.from_now)
    Contest.where(id: contest.id).update_all(payout_table_cents: table)
    contest
  end

  # Returns [exit status or nil, stdout + stderr, write statements].
  def run_reshape(slug, table:, write: false)
    ENV["WRITE"] = write ? "1" : nil
    ENV["TABLE_CENTS"] = table&.join(",")
    writes = []
    callback = ->(*, payload) { writes << payload[:sql] if payload[:sql].to_s.match?(WRITE_SQL) }
    status = nil
    output = ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      capture_io do
        Rake::Task["contests:reshape_payout"].reenable
        Rake::Task["contests:reshape_payout"].invoke(slug)
      rescue SystemExit => e
        status = e.status
      end
    end
    [status, output.join, writes]
  end

  def table_of(contest) = Contest.where(id: contest.id).pick(:payout_table_cents)

  test "without WRITE=1 it prints the table it would write and changes nothing" do
    status, output, writes = run_reshape(@contest.slug, table: FOUR_RANKS)

    assert_nil status
    assert_includes output, FOUR_RANKS.inspect
    assert_match(/dry run/i, output)
    assert_empty writes
    assert_equal NINE_RANKS, table_of(@contest)
  end

  test "with WRITE=1 it writes the passed table onto that contest alone" do
    status, _output, writes = run_reshape(@contest.slug, table: FOUR_RANKS, write: true)

    assert_nil status
    assert_equal FOUR_RANKS, table_of(@contest)
    assert_equal NINE_RANKS, table_of(@sibling)
    assert_equal 1, writes.size
    assert_match(/\AUPDATE "contests" SET "payout_table_cents" = /, writes.first)
    assert_equal FOUR_RANKS.sum, @contest.reload.guaranteed_prize_cents
  end

  test "a table whose sum differs from the pool is refused" do
    status, output, writes = run_reshape(@contest.slug, table: [1000_00, 400_00, 200_00, 100_00], write: true)

    assert_equal 1, status
    assert_match(/sums to 170000.*pool is 180000/, output)
    assert_empty writes
    assert_equal NINE_RANKS, table_of(@contest)
  end

  test "a table over MAX_PAID_RANKS is refused" do
    status, output, writes = run_reshape(@contest.slug, table: [1000_00, 400_00, 200_00, 100_00, 100_00], write: true)

    assert_equal 1, status
    assert_match(/5 paid ranks.*at most 4/, output)
    assert_empty writes
    assert_equal NINE_RANKS, table_of(@contest)
  end

  test "a settled contest is refused" do
    settled = make_contest!(NINE_RANKS, status: "settled")
    status, output, writes = run_reshape(settled.slug, table: FOUR_RANKS, write: true)

    assert_equal 1, status
    assert_match(/settled/, output)
    assert_empty writes
  end

  test "a graded contest whose settlement is pending is refused: its payouts are fixed" do
    pending = make_contest!(NINE_RANKS, status: "settlement_pending")
    status, output, writes = run_reshape(pending.slug, table: FOUR_RANKS, write: true)

    assert_equal 1, status
    assert_match(/graded or settled/, output)
    assert_empty writes
  end

  test "a missing or malformed table is refused" do
    [nil, [], ["180000", "abc"], ["0x2bf20"], [1800_00, 0], [1900_00, -100_00]].each do |table|
      status, output, writes = run_reshape(@contest.slug, table: table, write: true)

      assert_equal 1, status, table.inspect
      assert_match(/TABLE_CENTS/, output)
      assert_empty writes
    end
    assert_equal NINE_RANKS, table_of(@contest)
  end

  test "an unknown slug is refused" do
    status, output, writes = run_reshape("no-such-contest", table: FOUR_RANKS, write: true)

    assert_equal 1, status
    assert_match(/no contest/i, output)
    assert_empty writes
  end
end
