require "test_helper"
require "rake"

# contests:payout_census through the rake task, against real rows.
class ContestsPayoutCensusTest < ActiveSupport::TestCase
  NINE_RANKS = ([1000_00] + [100_00] * 8).freeze
  FOUR_RANKS = [1000_00, 400_00, 200_00, 200_00].freeze

  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("contests:payout_census")
    @over = make_contest!("large", NINE_RANKS)
    @fits = make_contest!("large", FOUR_RANKS)
    @settled = make_contest!("large", NINE_RANKS, status: "settled")
    @untabled = make_contest!("standard", nil)
    @retired = make_contest!("retired-format", nil)
  end

  # The column is attr_readonly and a table over four ranks is refused on
  # create, so the table is written below the model.
  def make_contest!(type, table, status: "open")
    contest = Contest.create!(name: "Census #{SecureRandom.hex(3)}", slate: slates(:one), contest_type: "tiny",
                              user: users(:alex), status: status, starts_at: 2.days.from_now)
    Contest.where(id: contest.id).update_all(contest_type: type, payout_table_cents: table)
    contest
  end

  def run_census
    capture_io do
      Rake::Task["contests:payout_census"].reenable
      Rake::Task["contests:payout_census"].invoke
    end.first
  end

  # Every statement the block issues, schema lookups aside, must be a SELECT.
  def assert_select_only(&block)
    statements = []
    callback = ->(*, payload) { statements << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record", &block)

    assert statements.any?, "expected the block to query"
    writes = statements.grep_v(/\A\s*SELECT\b/i)
    assert_empty writes, "expected SELECT only"
  end

  test "lists unsettled contests over four paid ranks with slug, type and rank count" do
    output = run_census

    assert_match(/^#{@over.slug}\s+large\s+open\s+no\s+9\s+snapshot$/, output)
    refute_includes output, @fits.slug
    refute_includes output, @settled.slug
  end

  test "lists unsettled rows with no table, by the ranks their format falls back to" do
    output = run_census

    assert_match(/^#{@untabled.slug}\s+standard\s+open\s+no\s+5\s+none$/, output)
    assert_match(/^#{@retired.slug}\s+retired-format\s+open\s+no\s+-\s+none$/, output)
  end

  test "marks a cancelled contest" do
    Contest.where(id: @over.id).update_all(onchain_cancelled: true)

    assert_match(/^#{@over.slug}\s+large\s+open\s+yes\s+9\s+snapshot$/, run_census)
  end

  test "prints no amounts" do
    refute_match(/\d{4,}|\$/, run_census.gsub(/census-\h+/, ""))
  end

  test "writes nothing" do
    assert_select_only { run_census }
  end

  test "control: an UPDATE fails the SELECT-only assertion" do
    assert_raises(Minitest::Assertion) do
      assert_select_only { Contest.where(id: @over.id).update_all(rank: 1) }
    end
  end
end
