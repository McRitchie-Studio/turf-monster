# frozen_string_literal: true

require "test_helper"
require "sidekiq-cron"

# THE SCHEDULE ACTUALLY ENQUEUES — the guard for a bug that ran in production, in both
# environments, from the day the first cron was added until 2026-08-26: NO scheduled job
# had ever executed. Every worker tick died at ENQUEUE with
#
#   undefined method `perform_async' for an instance of ActiveJob::ConfiguredJob
#
# ROOT CAUSE, and it is not the obvious one. sidekiq-cron picks its enqueue path from
# `Sidekiq::Cron::Job#is_active_job?`:
#
#   @active_job || defined?(ActiveJob::Base) && (klass || …) < ActiveJob::Base
#
# Read on its own that looks safe without the `active_job:` key — every job here is an
# ApplicationJob, so the second term should be true. It never is. The gem opens
# `module Sidekiq / module Cron / class Job`, so Ruby resolves the bare constant
# `ActiveJob` against THAT nesting, and Sidekiq 7 ships `Sidekiq::ActiveJob` — which has
# no `Base`. `defined?` therefore returns nil, the inference collapses to false for
# every ActiveJob in the world, and the gem calls `perform_async` on a class that has no
# such method. Measured in this repo (sidekiq 7.3.10 / sidekiq-cron 1.12.0):
#
#   Sidekiq::ActiveJob exists?       => true
#   Sidekiq::ActiveJob::Base exists? => false
#   klass < ActiveJob::Base          => true
#   is_active_job?(klass)            => nil      # ← both operands true, result falsy
#
# So on Sidekiq 7 the `active_job: true` key is NOT redundant belt-and-braces. It is the
# ONLY working signal, because it is the one term that short-circuits before the broken
# one.
#
# WHY THIS FILE EXISTS RATHER THAN A COMMENT IN THE YAML. The flags were added correctly
# on 2026-08-22 (3aa003e), and lost on 2026-08-25 in a merge resolution (4926d38) that
# took the other side of the file — silently, because nothing executed the schedule. A
# test in test/jobs/level_up_token_mint_job_test.rb that HAD asserted the flag was
# deleted in the same window, with a comment reasoning from the gem source to the
# conclusion that the flag was redundant. The reasoning was sound and the conclusion was
# wrong, which is exactly the shape of argument a prose comment cannot settle.
#
# Hence the second test below EXECUTES the enqueue rather than reading the YAML. A
# YAML-shape assertion can be argued away by the next careful reader of the gem; a job
# that fails to enqueue cannot.
class SidekiqCronScheduleTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper

  SCHEDULE = YAML.safe_load_file(Rails.root.join("config/schedule.yml")).freeze

  test "every scheduled ActiveJob declares the active_job flag" do
    assert SCHEDULE.any?, "config/schedule.yml must hold at least one entry"

    SCHEDULE.each do |name, config|
      klass = config.fetch("class").constantize
      next unless klass < ActiveJob::Base

      assert_equal true, config["active_job"],
                    "#{name}: #{klass} is an ActiveJob, so config/schedule.yml must carry " \
                    "`active_job: true`. Without it sidekiq-cron takes its Sidekiq-worker " \
                    "path and calls perform_async on an ActiveJob::ConfiguredJob — the " \
                    "inference that is supposed to catch this cannot fire on Sidekiq 7 " \
                    "(see this file's header)."
    end
  end

  # THE ONE THAT CANNOT BE ARGUED WITH: run the gem's own enqueue for every entry, the
  # way the cron poller does on a tick, and assert a job actually lands in the queue.
  # Against the schedule as it shipped this raises NoMethodError — the production error,
  # verbatim.
  test "a scheduled tick enqueues each job instead of raising" do
    SCHEDULE.each do |name, config|
      klass = config.fetch("class").constantize
      job = Sidekiq::Cron::Job.new(config.merge("name" => "#{name}-test"))

      assert_enqueued_with(job: klass) { job.enque! }

      # `last_enqueue_time` IS THE OPERATOR'S OWN CHECK, the one the /admin/jobs Cron
      # page shows and the acceptance criterion names ("verify by effect, not by
      # registration"). Asserted here so the signal watched on QA is the same signal
      # this suite proves — a registered cron is not a running cron, and only this
      # field tells the two apart.
      assert job.last_enqueue_time.present?,
             "#{name}: the tick left `last_enqueue_time` empty, which is exactly what a " \
             "registered-but-never-running cron looks like on /admin/jobs"
    end
  end

  # The failure mode the enqueue path has NO defence against, kept from the test this
  # replaces: `constantize` rescues NameError to nil and the run falls through to a raw
  # Sidekiq::Client.push, enqueueing a job nothing will ever perform. A typo'd cron then
  # fails silently, forever.
  test "every scheduled cron names a class that actually exists" do
    SCHEDULE.each do |name, config|
      klass = config.fetch("class")

      resolved = begin
        klass.constantize
      rescue NameError
        nil
      end

      assert resolved, "#{name}: schedule.yml names #{klass}, which does not resolve — " \
                       "sidekiq-cron rescues that to nil and silently enqueues a job " \
                       "no worker can perform"
    end
  end
end
