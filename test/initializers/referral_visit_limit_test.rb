require "test_helper"

# [unit] Rack::Attack.referral_visit_allowed? (config/initializers/rack_attack.rb):
# the per-address cap on referral_visits writes. The over-the-limit path through
# a real request is in test/integration/referral_visit_tracking_test.rb.
class ReferralVisitLimitTest < ActiveSupport::TestCase
  include RackAttackClock

  def request_from(ip)
    Rack::Attack::Request.new(Rack::MockRequest.env_for("/?reference=tiktok", "REMOTE_ADDR" => ip))
  end

  # The clock is frozen for the block so its counts land in one bucket
  # (test/support/rack_attack_clock.rb).
  def with_rack_attack(store = ActiveSupport::Cache::MemoryStore.new, &block)
    prior_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = store
    Rack::Attack.enabled = true
    in_one_rack_attack_period(Rack::Attack::REFERRAL_VISIT_PERIOD, &block)
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.cache.store = prior_store
  end

  test "allows up to the limit per address, then refuses" do
    with_rack_attack do
      req = request_from("203.0.113.7")
      allowed = Array.new(Rack::Attack::REFERRAL_VISIT_LIMIT + 2) { Rack::Attack.referral_visit_allowed?(req) }
      assert_equal [true] * Rack::Attack::REFERRAL_VISIT_LIMIT + [false, false], allowed
      assert Rack::Attack.referral_visit_allowed?(request_from("203.0.113.8")), "each address has its own bucket"
    end
  end

  # Production's store under a Redis outage: the error is swallowed, rack-attack
  # counts 1, and the click is recorded. Fail open, by decision: see the
  # "Cache outage" note at the top of config/initializers/rack_attack.rb.
  test "a Redis outage records every click, past the limit" do
    RedisCacheOutage.with_rack_attack do |swallowed|
      req = request_from("203.0.113.7")
      allowed = Array.new(Rack::Attack::REFERRAL_VISIT_LIMIT + 5) { Rack::Attack.referral_visit_allowed?(req) }
      assert_equal [true] * (Rack::Attack::REFERRAL_VISIT_LIMIT + 5), allowed
      assert swallowed.any? { |(_, error)| error.is_a?(Redis::BaseConnectionError) },
        "the store must actually have failed, and swallowed it: #{swallowed.map { |(m, e)| [m, e.class] }.inspect}"
    end
  end

  # No production store raises, but one that does is treated the same way.
  test "a store that raises also records the click" do
    broken = ActiveSupport::Cache::MemoryStore.new
    def broken.increment(*) = raise(Redis::CannotConnectError, "down")
    def broken.write(*) = raise(Redis::CannotConnectError, "down")
    with_rack_attack(broken) do
      assert Rack::Attack.referral_visit_allowed?(request_from("203.0.113.7"))
    end
  end

  test "disabled rack-attack allows every write" do
    assert Rack::Attack.referral_visit_allowed?(request_from("203.0.113.7"))
  end
end
