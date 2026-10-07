require "test_helper"

class EmailDeliveryTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActionMailer::TestHelper

  setup do
    @user = users(:alex)
  end

  # Capture is pinned OFF by test_helper's per-test baseline. A reset to nil
  # here would hand the decision back to LOCAL_EMAIL_CAPTURE / AGENT_WORKTREE,
  # which is how a ship workspace's .env failed this suite while CI passed.
  test "the suite baseline keeps capture off whatever the environment says" do
    with_env("LOCAL_EMAIL_CAPTURE" => "1", "AGENT_WORKTREE" => "1") do
      assert_not Studio.local_email_capture?
    end
  end

  test "deliver records a durable unsent row and enqueues the send job" do
    rec = nil
    assert_enqueued_with(job: EmailDeliveryJob) do
      assert_difference "EmailDelivery.count", 1 do
        rec = EmailDelivery.deliver(NewsletterMailer, :welcome, @user, to: @user.email, user: @user)
      end
    end
    assert_equal "NewsletterMailer#welcome", rec.email_key
    assert_equal @user.email, rec.to
    assert_equal @user, rec.user
    assert_not rec.sent?
  end

  test "deliver_now! rebuilds the mailer from stored args, sends, and marks sent" do
    rec = EmailDelivery.deliver(NewsletterMailer, :welcome, @user, to: @user.email)
    assert_emails 1 do
      rec.deliver_now!
    end
    assert rec.reload.sent?
    assert_not_nil rec.sent_at
    assert_equal [@user.email], ActionMailer::Base.deliveries.last.to
  end

  test "keyword args survive the serialize/deserialize roundtrip" do
    rec = EmailDelivery.deliver(UserMailer, :magic_link, @user.email, "tok", to: @user.email, contest: contests(:one))
    assert_nothing_raised { rec.deliver_now! }
    assert rec.reload.sent?
  end

  test "resend_unsent! re-enqueues only the unsent rows (outage recovery)" do
    EmailDelivery.deliver(NewsletterMailer, :welcome, @user, to: @user.email).update!(sent: true)
    EmailDelivery.deliver(NewsletterMailer, :welcome, @user, to: @user.email) # stays unsent
    clear_enqueued_jobs

    assert_enqueued_jobs 1, only: EmailDeliveryJob do
      EmailDelivery.resend_unsent!
    end
  end

  test "local email capture records without enqueueing" do
    Studio.local_email_capture = true

    assert_no_enqueued_jobs only: EmailDeliveryJob do
      assert_difference "EmailDelivery.count", 1 do
        EmailDelivery.deliver(UserMailer, :magic_link, @user.email, "tok", to: @user.email)
      end
    end

    assert_not EmailDelivery.recent.first.sent?
  end

  private

  def with_env(vars)
    original = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    original.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end
end
