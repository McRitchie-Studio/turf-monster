# frozen_string_literal: true

require "test_helper"
require "sidekiq-cron"

# [unit] The app runs Sidekiq, so sidekiq-cron's config/schedule.yml is the only
# schedule that executes. ErrorLogCleanupJob (studio-engine) prunes error_logs
# nightly from there; Solid Queue's config/recurring.yml and config/solid_queue.yml
# are not read by anything and stay deleted, so the job cannot drift back into a
# file no process loads.
class ErrorLogCleanupScheduleTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  ENTRY = "error_log_cleanup"

  def schedule = YAML.safe_load_file(Rails.root.join("config/schedule.yml"))

  test "schedule.yml declares the cleanup job with a valid nightly cron" do
    config = schedule.fetch(ENTRY) { flunk "config/schedule.yml has no #{ENTRY} entry" }

    assert_equal "ErrorLogCleanupJob", config["class"]
    assert_equal true, config["active_job"], "an ActiveJob entry needs active_job: true on Sidekiq 7"

    cron = Fugit::Cron.parse(config["cron"])
    assert cron, "#{config['cron'].inspect} is not a cron line Fugit can parse"
    first = cron.next_time(Time.utc(2026, 1, 1)).to_t
    second = cron.next_time(first + 1).to_t
    assert_in_delta 1.day, second - first, 1, "the cleanup runs once a day"
  end

  test "a tick enqueues the job with its default retention" do
    job = Sidekiq::Cron::Job.new(schedule.fetch(ENTRY).merge("name" => "#{ENTRY}-test"))

    assert_enqueued_with(job: ErrorLogCleanupJob, args: []) { job.enque! }
  end

  test "no Solid Queue schedule or config remains for the job to drift into" do
    %w[config/recurring.yml config/solid_queue.yml].each do |path|
      assert_not Rails.root.join(path).exist?, "#{path} is Solid Queue's format; this app runs Sidekiq"
    end
  end
end
