require "test_helper"

# [integration] POST /drop-signups queues the confirmation email exactly once
# per address per drop, and the response never reveals whether one was queued
# or which variant (new player / existing account) it will be.
class DropSignupConfirmationTest < ActionDispatch::IntegrationTest
  def post_json(ip: "198.51.100.10", **params)
    post drop_signups_path, params: params,
                            headers: { "Accept" => "application/json", "REMOTE_ADDR" => ip }
  end

  def confirmations(email)
    EmailDelivery.where(email_key: "DropSignupMailer#confirmation", to: email)
  end

  test "a new signup queues one confirmation and stamps the row" do
    post_json(email: "Fan@Example.com")
    assert_response :success
    assert_equal 1, confirmations("fan@example.com").count
    assert DropSignup.last.confirmation_sent_at.present?
  end

  test "a duplicate submit does not queue a second confirmation" do
    post_json(email: "fan@example.com")
    post_json(email: " FAN@example.com ")
    assert_equal 1, confirmations("fan@example.com").count
  end

  test "the same address from many IPs is still mailed once" do
    %w[198.51.100.1 198.51.100.2 203.0.113.9].each { |ip| post_json(email: "fan@example.com", ip: ip) }
    assert_equal 1, confirmations("fan@example.com").count
  end

  test "a honeypot submit mails nobody" do
    post_json(email: "bot@example.com", website: "http://spam.example")
    assert_response :success
    assert_equal 0, confirmations("bot@example.com").count
  end

  test "a malformed address mails nobody" do
    post_json(email: "not-an-email")
    assert_equal 0, EmailDelivery.where(email_key: "DropSignupMailer#confirmation").count
  end

  test "the response is identical for an address with an account and one without" do
    post_json(email: users(:sam).email)
    existing = [response.status, response.body]
    post_json(email: "nobody-yet@example.com")
    assert_equal existing, [response.status, response.body]
  end

  test "a confirmation that fails to queue still answers ok and can be retried" do
    Studio::Email.stub(:deliver, ->(*, **) { raise "outbox down" }) do
      post_json(email: "fan@example.com")
    end
    assert_response :success
    assert_nil DropSignup.last.confirmation_sent_at, "the claim was released"

    post_json(email: "fan@example.com")
    assert_equal 1, confirmations("fan@example.com").count, "the next submit queues it"
  end
end
