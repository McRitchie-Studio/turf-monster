require "test_helper"

# [unit] ExperimentReport: the per-variant numbers from fixture rows, the
# window, the two-proportion z-test against known values, and the honest
# significance hint (nothing called ahead below the minimum sample or p < 0.05).
class ExperimentReportTest < ActiveSupport::TestCase
  include PageExperimentFixture

  setup do
    @experiment = create_page_experiment
    @today = Date.new(2026, 10, 6)
  end

  def visitor(n) = format("00000000-0000-4000-8000-%012d", n)

  def event(variant, event, n, on: @today)
    ExperimentEvent.record(experiment_slug: "turf-monster-v2", variant_key: variant, event: event,
                           visitor_id: visitor(n), at: on.to_time.change(hour: 12))
  end

  def email_signup(variant, n, at: @today.to_time.change(hour: 13))
    DropSignup.create!(email: "v#{n}@example.com", slate_key: "s", experiment_slug: "turf-monster-v2",
                       variant_key: variant, created_at: at)
  end

  # --- the z-test ---------------------------------------------------------------

  test "the p-value matches a hand-worked pooled two-proportion z-test" do
    # 10/100 vs 20/100: pooled 0.15, SE = sqrt(0.15 * 0.85 * 0.02) = 0.050498,
    # z = 0.10 / 0.050498 = 1.9803, two-sided p = 0.04767.
    assert_in_delta 0.04767, ExperimentReport.two_proportion_p_value(10, 100, 20, 100), 0.0001
    # 50/1000 vs 50/1000: no difference at all.
    assert_in_delta 1.0, ExperimentReport.two_proportion_p_value(50, 1000, 50, 1000), 1e-9
    # 30/200 vs 60/200: pooled 0.225, SE = sqrt(0.225 * 0.775 * 0.01) = 0.041758,
    # z = 0.15 / 0.041758 = 3.592, p = 0.000328.
    assert_in_delta 0.000328, ExperimentReport.two_proportion_p_value(30, 200, 60, 200), 0.000005
    # Symmetric in the arms.
    assert_in_delta ExperimentReport.two_proportion_p_value(20, 100, 10, 100),
                    ExperimentReport.two_proportion_p_value(10, 100, 20, 100), 1e-12
  end

  test "an empty arm has no p-value; no successes anywhere is p = 1; successes are capped at the sample" do
    assert_nil ExperimentReport.two_proportion_p_value(0, 0, 5, 10)
    assert_equal 1.0, ExperimentReport.two_proportion_p_value(0, 50, 0, 50)
    assert_equal ExperimentReport.two_proportion_p_value(10, 10, 0, 10),
                 ExperimentReport.two_proportion_p_value(25, 10, 0, 10)
  end

  # --- the numbers -----------------------------------------------------------------

  test "visitors, hits, taps and signups per variant, from the rows" do
    event("control", "visit", 1)
    event("control", "visit", 1, on: @today - 1) # the same person, another day: a second hit
    event("control", "visit", 2)
    event("control", "cta:play", 1)
    event("fantasy-football", "visit", 3)
    event("fantasy-football", "cta:play", 3)
    event("fantasy-football", "cta:notify", 3)
    email_signup("fantasy-football", 3)
    users(:jordan).update_columns(experiment_slug: "turf-monster-v2", variant_key: "control")
    DropSignup.create!(email: "other@example.com", slate_key: "s", experiment_slug: "another", variant_key: "control")

    report = ExperimentReport.new(@experiment, window: "all", today: @today)
    control, ff = report.rows
    assert_equal %w[control fantasy-football], report.rows.map(&:key)

    assert_equal [2, 3, 1, 0, 0, 1], [control.visitors, control.hits, control.ctas["play"], control.ctas["notify"],
                                      control.email_signups, control.account_signups]
    assert_equal [1, 1, 1, 1, 1, 0], [ff.visitors, ff.hits, ff.ctas["play"], ff.ctas["notify"],
                                      ff.email_signups, ff.account_signups]
    assert_equal 50.0, control.cta_rate("play")
    assert_equal 100.0, ff.email_rate
    assert_nil ExperimentReport.new(@experiment, today: @today).rows.first.cta_rate("watch_live").nonzero?
  end

  test "the window drops older events and signups" do
    event("control", "visit", 1, on: @today - 10)
    event("control", "visit", 2)
    email_signup("control", 1, at: (@today - 10).to_time)
    report = ExperimentReport.new(@experiment, window: "7", today: @today)
    assert_equal [1, 0], [report.rows.first.visitors, report.rows.first.email_signups]
    assert_equal 2, ExperimentReport.new(@experiment, window: "all", today: @today).rows.first.visitors
  end

  # --- the hint ----------------------------------------------------------------------

  def fill(variant, visitors:, signups:, offset:)
    visitors.times { |i| event(variant, "visit", offset + i) }
    signups.times { |i| email_signup(variant, offset + i) }
  end

  test "below the minimum sample it says not significant yet, however big the gap" do
    fill("control", visitors: 20, signups: 0, offset: 0)
    fill("fantasy-football", visitors: 20, signups: 15, offset: 1000)
    hint = ExperimentReport.new(@experiment, today: @today).significance["fantasy-football"]
    assert_equal :not_yet, hint.verdict
    assert_match(/Not significant yet/, hint.label)
    assert hint.p_value < 0.05, "the gap is real-looking, and still not called"
  end

  test "with enough visitors, p < 0.05 calls the arm ahead; otherwise no significant difference" do
    fill("control", visitors: 100, signups: 10, offset: 0)
    fill("fantasy-football", visitors: 100, signups: 25, offset: 1000)
    hint = ExperimentReport.new(@experiment, today: @today).significance["fantasy-football"]
    assert_equal :ahead, hint.verdict
    assert_match(/p = 0\.00/, hint.label)

    DropSignup.where(variant_key: "fantasy-football").limit(13).delete_all
    hint = ExperimentReport.new(@experiment, today: @today).significance["fantasy-football"]
    assert_equal :no_difference, hint.verdict
  end

  test "the control has no hint of its own" do
    report = ExperimentReport.new(@experiment, today: @today)
    assert_equal ["fantasy-football"], report.significance.keys
  end
end
