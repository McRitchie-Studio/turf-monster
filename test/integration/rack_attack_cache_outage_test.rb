require "test_helper"

# [integration] Real requests through the Rack::Attack middleware while Redis is
# down (config/initializers/rack_attack.rb, "Cache outage"). The store is
# RedisCacheOutage: production's store class with its errors swallowed. The rule
# by rule unit proof is test/initializers/rack_attack_cache_outage_test.rb.
class RackAttackCacheOutageIntegrationTest < ActionDispatch::IntegrationTest
  include RackAttackClock

  EMAIL = "fan@example.com".freeze

  def failed_logins(times)
    Array.new(times) do
      post "/login", params: { email: EMAIL, password: "wrong-password" }
      response.status
    end
  end

  # The clock is frozen so the flood counts into one bucket
  # (test/support/rack_attack_clock.rb).
  test "with Redis up, a sign-in flood on one address is a 429 past the limit" do
    prior_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.enabled = true
    throttle = Rack::Attack.throttles.fetch("login/email")
    limit = throttle.limit

    statuses = in_one_rack_attack_period(throttle.period) { failed_logins(limit + 1) }
    refute_includes statuses.first(limit), 429
    assert_equal 429, statuses.last
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.cache.store = prior_store
  end

  test "with Redis down, the same flood is never a 429: sign-in fails open, it does not lock everyone out" do
    limit = Rack::Attack.throttles.fetch("login/email").limit

    RedisCacheOutage.with_rack_attack do |swallowed|
      statuses = failed_logins(limit * 3)
      refute_includes statuses, 429
      assert statuses.all? { |status| status < 500 }, "a Redis outage must not 500 sign-in: #{statuses.inspect}"
      refute_empty swallowed, "the store must actually have failed"
    end
  end
end
