# frozen_string_literal: true

require "test_helper"
require "sidekiq-cron"

# [unit] Turf Monster turns on studio-engine's daily health report
# (studio-engine docs/HEALTH_REPORT.md, /tasks/turf-daily-health-report). The
# engine sends nothing until a host does BOTH: schedules Studio::HealthReportJob
# and names a recipient. This file holds each half, and proves the QA_ENV guard
# still stops a QA dyno from sending.
class HealthReportScheduleTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  ENTRY = "studio_health_report"
  RECIPIENT = "alex@mcritchie.studio"

  def schedule = YAML.safe_load_file(Rails.root.join("config/schedule.yml"))
  def entry = schedule.fetch(ENTRY) { flunk "config/schedule.yml has no #{ENTRY} entry" }

  test "schedule.yml runs the engine job daily at 07:00 Denver with active_job" do
    assert_equal "Studio::HealthReportJob", entry["class"]
    assert_equal true, entry["active_job"], "an ActiveJob entry needs active_job: true on Sidekiq 7"

    cron = Fugit::Cron.parse(entry["cron"])
    assert cron, "#{entry['cron'].inspect} is not a cron line Fugit can parse"

    # Measured across both DST edges, so a UTC cron that is right half the year fails.
    [Time.utc(2026, 1, 15), Time.utc(2026, 7, 15)].each do |from|
      run = cron.next_time(from).to_t.in_time_zone("America/Denver")
      assert_equal [7, 0], [run.hour, run.min], "the report runs at 07:00 Denver wall clock (#{from.to_date})"
      following = cron.next_time(cron.next_time(from).to_t + 1).to_t
      assert_in_delta 1.day, following - run, 1, "the report runs once a day"
    end
  end

  test "the cron zone matches the zone and hour the report window is cut on" do
    assert_equal "America/Denver", Studio.health_report_zone
    assert_equal 7, Studio.health_report_hour
  end

  test "a tick enqueues Studio::HealthReportJob" do
    job = Sidekiq::Cron::Job.new(entry.merge("name" => "#{ENTRY}-test"))

    assert_enqueued_with(job: Studio::HealthReportJob) { job.enque! }
  end

  test "the Studio initializer names the recipient" do
    assert_equal RECIPIENT, Studio.health_report_to
    assert_equal [RECIPIENT], Studio::HealthReport.recipients
  end

  test "a run outside QA queues the report to the recipient" do
    with_qa_env(nil) do
      assert_difference -> { EmailDelivery.where(email_key: "Studio::HealthReportMailer#daily").count }, 1 do
        Studio::HealthReportJob.perform_now
      end
    end
    assert_equal RECIPIENT, EmailDelivery.where(email_key: "Studio::HealthReportMailer#daily").last.to
  end

  test "a QA run sends nothing" do
    with_qa_env("true") do
      assert_no_difference -> { EmailDelivery.count } do
        Studio::HealthReportJob.perform_now
      end
    end
  end

  private

  def with_qa_env(value)
    previous = ENV.fetch("QA_ENV", nil)
    value.nil? ? ENV.delete("QA_ENV") : ENV["QA_ENV"] = value
    yield
  ensure
    previous.nil? ? ENV.delete("QA_ENV") : ENV["QA_ENV"] = previous
  end
end
