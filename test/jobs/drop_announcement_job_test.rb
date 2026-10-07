require "test_helper"

# [unit] DropAnnouncementJob queues the announcement once per owed address and
# is safe to run again.
class DropAnnouncementJobTest < ActiveJob::TestCase
  KEY = NextSlateDrop::SLATE_KEY

  def announcements = EmailDelivery.where(email_key: "DropSignupMailer#announcement")

  test "queues one announcement per owed address and skips notified and unsubscribed" do
    owed = DropSignup.create!(email: "a@example.com", slate_key: KEY)
    DropSignup.create!(email: "done@example.com", slate_key: KEY, notified_at: 1.day.ago)
    DropSignup.create!(email: "gone@example.com", slate_key: KEY, unsubscribed_at: 1.day.ago)

    assert_equal({ queued: 1, failed: 0 }, DropAnnouncementJob.perform_now(KEY))
    assert_equal ["a@example.com"], announcements.pluck(:to)
    assert_equal announcements.first.id, owed.reload.announcement_delivery_id
  end

  test "a retry or a second run mails nobody twice" do
    DropSignup.create!(email: "a@example.com", slate_key: KEY)
    DropAnnouncementJob.perform_now(KEY)
    assert_equal({ queued: 0, failed: 0 }, DropAnnouncementJob.perform_now(KEY))
    assert_equal 1, announcements.count
  end

  test "one row failing to queue does not stop the rest, and stays owed" do
    DropSignup.create!(email: "bad@example.com", slate_key: KEY)
    DropSignup.create!(email: "good@example.com", slate_key: KEY)
    real = Studio::Email.method(:deliver)
    flaky = lambda do |*args, to:, **kw|
      raise "smtp down" if to == "bad@example.com"

      real.call(*args, to: to, **kw)
    end

    result = Studio::Email.stub(:deliver, flaky) { DropAnnouncementJob.perform_now(KEY) }

    assert_equal({ queued: 1, failed: 1 }, result)
    assert_equal ["bad@example.com"], DropSignup.announceable(KEY).pluck(:email)
  end
end
