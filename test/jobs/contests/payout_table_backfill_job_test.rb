require "test_helper"

class Contests::PayoutTableBackfillJobTest < ActiveJob::TestCase
  setup do
    Contest.update_all(payout_table_cents: nil)
  end

  def run_job
    out = nil
    capture_io { out = Contests::PayoutTableBackfillJob.perform_now }
    out
  end

  test "writes the table each contest opened with, by format" do
    standard = contests(:one)
    large = Contest.create!(name: "Old large", slate: slates(:one), status: :open, contest_type: "large")
    Contest.where(id: large.id).update_all(payout_table_cents: nil)

    run_job

    assert_equal [300_00, 50_00, 50_00, 50_00, 50_00], standard.reload.payout_table_cents
    assert_equal [1000_00] + [100_00] * 8, large.reload.payout_table_cents
    assert_equal 500_00, standard.guaranteed_prize_cents
  end

  test "leaves a snapshotted contest alone and is safe to run again" do
    fresh = Contest.create!(name: "New standard", slate: slates(:one), status: :open, contest_type: "standard")

    run_job
    assert_equal 0, run_job

    assert_equal [300_00, 100_00, 50_00, 50_00], fresh.reload.payout_table_cents
  end

  test "a retired format keeps reading its entries" do
    retired = contests(:one)
    Contest.where(id: retired.id).update_all(contest_type: "survivor")

    run_job

    assert_nil retired.reload.payout_table_cents
  end
end
