require "test_helper"
require "rake"

# [unit] drop_signups:send_missing_confirmations — the deploy's one-time
# backfill (lib/tasks/drop_signups.rake). It runs DropSignup's own claim, so
# running it twice mails nobody twice; it prints what it did.
class DropSignupsSendMissingConfirmationsTaskTest < ActiveSupport::TestCase
  setup do
    Rails.application.load_tasks unless Rake::Task.task_defined?("drop_signups:send_missing_confirmations")
    @task = Rake::Task["drop_signups:send_missing_confirmations"]
    @task.reenable
  end

  def run_task
    out, = capture_io { @task.invoke }
    @task.reenable
    out
  end

  test "queues the missing confirmations, prints the count, and a second run queues none" do
    DropSignup.create!(email: "old@example.com", slate_key: NextSlateDrop::SLATE_KEY)
    DropSignup.create!(email: "gone@example.com", slate_key: NextSlateDrop::SLATE_KEY, unsubscribed_at: 1.day.ago)

    assert_match(/queued=1 skipped=0 failed=0/, run_task)
    assert_match(/queued=0 skipped=0 failed=0/, run_task)
    assert_equal ["old@example.com"], EmailDelivery.where(email_key: "DropSignupMailer#confirmation").pluck(:to)
  end
end
