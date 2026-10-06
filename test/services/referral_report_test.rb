require "test_helper"

# [unit] ReferralReport: the funnel math, the window, the per-day table, and
# both branches of the email-signup source (DropSignup ships in its own task,
# so it is injected here through a stand-in table, never the real class).
class ReferralReportTest < ActiveSupport::TestCase
  TODAY = Date.new(2026, 10, 5)

  # A stand-in for DropSignup: a table with the two columns the report reads.
  # Created inside the test's transaction (Postgres DDL is transactional), so
  # it rolls back with the test. Not TEMPORARY: Rails' table_exists? does not
  # look in pg_temp.
  class StandInEmail < ApplicationRecord
    self.table_name = "referral_report_stand_in_emails"
  end

  setup do
    travel_to TODAY.to_time.change(hour: 12)
    User.update_all(reference: nil)
  end

  def create_stand_in_table
    ActiveRecord::Base.connection.create_table(:referral_report_stand_in_emails) do |t|
      t.string :source
      t.datetime :created_at, null: false
    end
    reset_stand_in
  end

  def reset_stand_in
    StandInEmail.connection.schema_cache.clear_data_source_cache!(StandInEmail.table_name)
    StandInEmail.reset_column_information
  end

  teardown { reset_stand_in }

  def visit(ref, visitor, on: TODAY, path: "/")
    ReferralVisit.record(reference: ref, visitor_id: visitor, path: path, at: on.to_time.change(hour: 10))
  end

  def vid(n) = format("00000000-0000-4000-8000-%012d", n)

  def signup(user_label, reference, at: Time.current)
    users(user_label).update_columns(reference: reference, created_at: at)
  end

  def row(report, ref) = report.rows.find { |r| r.reference == ref }

  # --- the email source -------------------------------------------------------

  test "no email model: an undefined constant reads as absent, never raises" do
    assert_nil ReferralReport.email_signup_model("NoSuchDropSignupModel")
    report = ReferralReport.new(email_model: nil)
    refute report.emails?
  end

  test "a model whose table is missing reads as absent" do
    assert_nil ReferralReport.email_signup_model("ReferralReportTest::StandInEmail")
  end

  test "a model with a table and a source column is used" do
    create_stand_in_table
    assert_equal StandInEmail, ReferralReport.email_signup_model("ReferralReportTest::StandInEmail")
  end

  # --- the funnel -------------------------------------------------------------

  test "clicks, visitors, signups and rates per reference, with emails" do
    create_stand_in_table
    visit("tiktok", vid(1))
    visit("tiktok", vid(1), on: TODAY - 1)          # same visitor, another day: a 2nd click, same visitor
    visit("tiktok", vid(2), path: "/lp/tiktok")
    visit("tiktok", vid(3))
    visit("tiktok", vid(4))
    visit("ig", vid(5))
    signup(:jordan, "TikTok")                       # raw case on the user still groups
    StandInEmail.create!(source: "tiktok", created_at: Time.current)
    StandInEmail.create!(source: " TIKTOK", created_at: Time.current)
    StandInEmail.create!(source: "newsletter", created_at: Time.current)

    report = ReferralReport.new(window: "30", email_model: StandInEmail, today: TODAY)
    tiktok = row(report, "tiktok")

    assert_equal 5, tiktok.clicks
    assert_equal 4, tiktok.visitors
    assert_equal 2, tiktok.email_signups
    assert_equal 1, tiktok.account_signups
    assert_equal 50.0, tiktok.email_rate
    assert_equal 25.0, tiktok.account_rate
    assert_equal ["/", 4], tiktok.top_paths.first

    newsletter = row(report, "newsletter")
    assert_equal 0, newsletter.clicks
    assert_nil newsletter.email_rate, "no visitors means no rate, not a division by zero"
    assert_equal %w[tiktok ig newsletter], report.rows.map(&:reference)

    assert_equal 6, report.totals.clicks
    assert_equal 5, report.totals.visitors
    assert_equal 3, report.totals.email_signups
  end

  test "without an email model the email counts are nil, not zero" do
    visit("tiktok", vid(1))
    report = ReferralReport.new(email_model: nil, today: TODAY)
    assert_nil row(report, "tiktok").email_signups
    assert_nil report.totals.email_signups
  end

  test "the window bounds clicks and signups; all time does not" do
    visit("tiktok", vid(1), on: TODAY - 6)
    visit("tiktok", vid(2), on: TODAY - 7)
    signup(:jordan, "tiktok", at: 3.days.ago)
    signup(:sam, "tiktok", at: 40.days.ago)

    week = ReferralReport.new(window: "7", email_model: nil, today: TODAY)
    assert_equal TODAY - 6, week.since_date
    assert_equal 1, row(week, "tiktok").clicks
    assert_equal 1, row(week, "tiktok").account_signups

    all = ReferralReport.new(window: "all", email_model: nil, today: TODAY)
    assert_equal 2, row(all, "tiktok").clicks
    assert_equal 2, row(all, "tiktok").account_signups
  end

  test "an unknown window falls back to 30 days" do
    assert_equal "30", ReferralReport.new(window: "9000", email_model: nil).window
    assert_equal "30", ReferralReport.new(window: nil, email_model: nil).window
  end

  # --- per day ------------------------------------------------------------------

  test "a bounded window lists every day, zeros included, newest first" do
    create_stand_in_table
    visit("tiktok", vid(1))
    visit("tiktok", vid(2))
    visit("tiktok", vid(1), on: TODAY - 2)
    signup(:jordan, "tiktok", at: (TODAY - 2).to_time.change(hour: 15))
    StandInEmail.create!(source: "tiktok", created_at: Time.current)

    days = ReferralReport.new(window: "7", email_model: StandInEmail, today: TODAY).daily("TikTok")

    assert_equal 7, days.size
    assert_equal TODAY, days.first.date
    assert_equal [2, 0, 1], days.first(3).map(&:clicks)
    assert_equal [0, 0, 1], days.first(3).map(&:account_signups)
    assert_equal [1, 0, 0], days.first(3).map(&:email_signups)
  end

  test "all time lists only days with activity" do
    visit("tiktok", vid(1), on: TODAY - 100)
    visit("tiktok", vid(1))
    days = ReferralReport.new(window: "all", email_model: nil, today: TODAY).daily("tiktok")
    assert_equal [TODAY, TODAY - 100], days.map(&:date)
    assert_nil days.first.email_signups
  end
end
