require "test_helper"

# [integration] rack-attack is disabled in test, so this calls the throttle
# discriminators directly (the pattern rate_limit_responder_test.rb uses): does
# POST /drop-signups produce a key, or fall through as EXEMPT?
class DropSignupThrottleTest < ActiveSupport::TestCase
  def key_for(name, path, method: "POST", params: {})
    env = Rack::MockRequest.env_for(path, method: method, params: params)
    env["REMOTE_ADDR"] = "203.0.113.7"
    Rack::Attack.throttles.fetch(name).block.call(Rack::Attack::Request.new(env))
  end

  test "the signup endpoint is throttled per IP" do
    assert_equal "203.0.113.7", key_for("drop_signups/ip", "/drop-signups")
    assert_nil key_for("drop_signups/ip", "/drop-signups", method: "GET")
    assert_nil key_for("drop_signups/ip", "/contests")
  end

  test "the signup endpoint is throttled per normalized email" do
    assert_equal "fan@example.com", key_for("drop_signups/email", "/drop-signups", params: { email: " Fan@Example.com " })
    assert_nil key_for("drop_signups/email", "/drop-signups", params: {})
  end

  test "limits are an hour wide" do
    assert_equal 3600, Rack::Attack.throttles.fetch("drop_signups/ip").period
    assert_equal 5, Rack::Attack.throttles.fetch("drop_signups/email").limit
  end
end
