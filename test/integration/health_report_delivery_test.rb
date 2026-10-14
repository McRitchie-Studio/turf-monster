# frozen_string_literal: true

require "test_helper"

# [integration] The daily health report end to end in this app: the engine job
# reads Turf's own User and ErrorLog tables for the 07:00-to-07:00 Denver day,
# writes the report through Turf's EmailDelivery outbox (the app adapter
# Studio::Email prefers), and the outbox renders and sends a real mail to the
# recipient the Studio initializer names. /tasks/turf-daily-health-report.
class HealthReportDeliveryTest < ActionDispatch::IntegrationTest
  RECIPIENT = "alex@mcritchie.studio"
  KEY = "Studio::HealthReportMailer#daily"

  setup do
    @qa_env = ENV.delete("QA_ENV")
    ActionMailer::Base.deliveries.clear
  end

  teardown { @qa_env.nil? ? ENV.delete("QA_ENV") : ENV["QA_ENV"] = @qa_env }

  test "a run reports the day's signups and errors to the recipient through the outbox" do
    now = Time.find_zone("America/Denver").local(2026, 10, 14, 7, 5)
    inside = now - 3.hours

    User.create!(email: "health-report-signup@example.com", created_at: inside)
    ErrorLog.capture!(RuntimeError.new("health report probe")).update_columns(created_at: inside)

    assert_difference -> { EmailDelivery.where(email_key: KEY).count }, 1 do
      Studio::HealthReportJob.perform_now(now)
    end

    delivery = EmailDelivery.where(email_key: KEY).last
    assert_equal RECIPIENT, delivery.to

    assert_difference -> { ActionMailer::Base.deliveries.size }, 1 do
      delivery.deliver_now!
    end
    assert delivery.reload.sent?, "the outbox row is marked sent: #{delivery.error.inspect}"

    mail = ActionMailer::Base.deliveries.last
    assert_equal [RECIPIENT], mail.to
    assert_match "Turf Monster", mail.subject
    body = mail.html_part ? mail.html_part.body.to_s : mail.body.to_s
    assert_includes body, "health-report-signup@example.com"
    assert_includes body, "health report probe"
  end
end
