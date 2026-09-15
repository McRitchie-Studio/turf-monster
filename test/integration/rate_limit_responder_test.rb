require "test_helper"

# Rate-limit epic, Phase 1 — the 429 response CONTRACT the client interceptor
# (authedFetch) depends on: a general-tier throttle must tag the 429 with
# X-RateLimit-Tier: general (header + body) so the global wait modal opens,
# while an auth-surface throttle tags "auth" so it's left to its own inline UX.
# Unit-tests the custom throttled_responder directly (rack-attack is disabled in
# test env; tripping the real middleware also pulls in Solana/auth side effects).
# The end-to-end trip → modal is verified manually on :3100.
class RateLimitResponderTest < ActiveSupport::TestCase
  def call_responder(matched:, period:)
    env = {
      "rack.attack.matched"    => matched,
      "rack.attack.match_data" => { period: period }
    }
    Rack::Attack.throttled_responder.call(ActionDispatch::Request.new(env))
  end

  test "a general-tier throttle tags the 429 general (header + body) with Retry-After" do
    status, headers, body = call_responder(matched: "faucet/ip", period: 60)

    assert_equal 429, status
    assert_equal "general", headers["X-RateLimit-Tier"]
    assert_equal "60", headers["Retry-After"]
    json = JSON.parse(body.first)
    assert_equal "general", json["tier"]
    assert_equal 60, json["retry_after"]
  end

  test "the new general/ip backstop is tagged general" do
    _, headers, body = call_responder(matched: "general/ip", period: 60)
    assert_equal "general", headers["X-RateLimit-Tier"]
    assert_equal "general", JSON.parse(body.first)["tier"]
  end

  test "the cdp_sessions/user throttle is tagged general (wait modal, not inline auth UX)" do
    _, headers, body = call_responder(matched: "cdp_sessions/user", period: 60)
    assert_equal "general", headers["X-RateLimit-Tier"]
    assert_equal "general", JSON.parse(body.first)["tier"]
  end

  test "the check_funding/ip throttle is tagged general (wait modal — beginFundingCheck uses authedFetch)" do
    _, headers, body = call_responder(matched: "check_funding/ip", period: 60)
    assert_equal "general", headers["X-RateLimit-Tier"]
    assert_equal "general", JSON.parse(body.first)["tier"]
  end

  test "an auth-surface throttle tags the 429 auth so the wait modal stays out of it" do
    _, headers, body = call_responder(matched: "magic_link/email", period: 3600)
    assert_equal "auth", headers["X-RateLimit-Tier"]
    assert_equal "auth", JSON.parse(body.first)["tier"]
  end
  test "the cdp_offramp_send/user throttle is tagged general (wait modal — the cash-out uses authedFetch)" do
    _, headers, body = call_responder(matched: "cdp_offramp_send/user", period: 60)
    assert_equal "general", headers["X-RateLimit-Tier"]
    assert_equal "general", JSON.parse(body.first)["tier"]
  end

  # THE CASH-OUT COSIGN ROUTE IS NOT EXEMPT. This file's own header notes that
  # rack-attack is DISABLED in test, so tripping the middleware is not the
  # assertion available here — but the throttles are still registered, and the
  # discriminator is a plain block. Calling it directly answers the only
  # question that matters for a money surface: does this path produce a key, or
  # does it fall through as EXEMPT the way every unlisted POST route does?
  #
  # POST /cdp/offramp/cosign_send spends admin SOL — since
  # phantom-cashout-needs-sol the house is the fee payer on the cash-out wire,
  # so every wire it returns is a broadcastable claim on SOLANA_ADMIN_KEY.
  def cosign_throttle_key(path, method: "POST", session: {})
    env = Rack::MockRequest.env_for(path, method: method)
    env["rack.session"] = session
    env["REMOTE_ADDR"] = "203.0.113.9"
    Rack::Attack.throttles.fetch("cdp_offramp_send/user").block.call(Rack::Attack::Request.new(env))
  end

  test "the admin-SOL cash-out routes are covered by a throttle, not exempt" do
    session = { Studio.session_key.to_s => 4242 }

    assert_equal "4242", cosign_throttle_key("/cdp/offramp/cosign_send", session: session),
                 "the cosign route spends admin SOL and must be capped per user"
    assert_equal "4242", cosign_throttle_key("/cdp/offramp/prepare_send", session: session),
                 "prepare precedes every cosign, so it is capped alongside it"
  end

  test "the cash-out throttle falls back to IP for an unauthenticated probe" do
    assert_equal "203.0.113.9", cosign_throttle_key("/cdp/offramp/cosign_send")
  end

  test "the cash-out throttle ignores other verbs and unrelated paths" do
    assert_nil cosign_throttle_key("/cdp/offramp/cosign_send", method: "GET")
    assert_nil cosign_throttle_key("/cdp/offramp/sent")
    assert_nil cosign_throttle_key("/contests")
  end

  test "the cash-out throttle is 10 per minute" do
    throttle = Rack::Attack.throttles.fetch("cdp_offramp_send/user")
    assert_equal 10, throttle.limit
    assert_equal 60, throttle.period
  end
  # THE EXACT-PATH MATCH IS ONLY AS GOOD AS THE ROUTE. The throttle above
  # compares req.path with ==, so a route that still accepts an optional
  # (.:format) segment is throttled at its bare path and EXEMPT at
  # /cdp/offramp/cosign_send.json — same action, same admin SOL, no cap. This
  # repo already learned that on the PayPal fee-bleed routes and fixed it with
  # `format: false` (config/routes.rb, tokens/paypal_order); the cash-out
  # routes now carry the same remedy, and this pins it.
  test "the admin-SOL cash-out routes refuse a .json suffix so the throttle cannot be bypassed" do
    %w[cosign_send prepare_send].each do |action|
      assert_raises(ActionController::RoutingError,
                    "POST /cdp/offramp/#{action}.json must not dispatch — it would reach the " \
                    "same action while skipping the cdp_offramp_send/user throttle") do
        Rails.application.routes.recognize_path("/cdp/offramp/#{action}.json", method: :post)
      end
    end
  end
end
