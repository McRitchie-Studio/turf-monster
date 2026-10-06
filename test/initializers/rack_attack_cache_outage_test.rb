require "test_helper"

# [unit] What every rack-attack rule does while Redis is down
# (config/initializers/rack_attack.rb, "Cache outage"): it fails open. Run
# against RedisCacheOutage, the store production uses with its error_handler
# swallowing, not a store that raises. Through real requests:
# test/integration/rack_attack_cache_outage_test.rb.
class RackAttackCacheOutageTest < ActiveSupport::TestCase
  def request_for(path, method: "POST", ip: "203.0.113.7", params: {})
    Rack::Attack::Request.new(Rack::MockRequest.env_for(path, method: method, params: params, "REMOTE_ADDR" => ip))
  end

  def connection_errors(swallowed)
    swallowed.map(&:last).select { |error| error.is_a?(Redis::BaseConnectionError) }
  end

  test "the outage store is the store production configures, swallowing its errors" do
    production = Rails.root.join("config/environments/production.rb").read
    assert_match(/^\s*config\.cache_store = :redis_cache_store, cache_store_options$/, production)
    assert_match(/^\s*error_handler: ->\(method:, returning:, exception:\) \{$/, production)

    RedisCacheOutage.with_rack_attack do
      assert_instance_of Rack::Attack::StoreProxy::RedisCacheStoreProxy, Rack::Attack.cache.store
      assert_instance_of ActiveSupport::Cache::RedisCacheStore, Rack::Attack.cache.store.__getobj__
    end
  end

  test "rack-attack counts 1 on every request while Redis is down, and nothing raises" do
    RedisCacheOutage.with_rack_attack do |swallowed|
      counts = Array.new(25) { Rack::Attack.cache.count("login/ip:203.0.113.7", 60) }
      assert_equal [1] * 25, counts
      refute_empty connection_errors(swallowed), "the store must actually have failed"
    end
  end

  test "no rule in the file throttles while Redis is down" do
    RedisCacheOutage.with_rack_attack do |swallowed|
      Rack::Attack.throttles.each do |name, rule|
        req = request_for("/anything")
        # The rule's own limit and period, with a discriminator that always matches.
        probe = Rack::Attack::Throttle.new(name, limit: rule.limit, period: rule.period) { "probe" }
        limit = probe.send(:limit_for, req)
        assert_operator limit, :>=, 1, "#{name}: a limit below 1 would throttle on a count of 1"

        refute probe.matched_by?(req), "#{name} throttled on the first request"
        refute probe.matched_by?(req), "#{name} throttled on the second request"
        assert_equal 1, req.env["rack.attack.throttle_data"][name][:count], "#{name} counted past 1"
      end
      refute_empty connection_errors(swallowed)
    end
  end

  test "a tight rule lets every request past its limit through while Redis is down" do
    rule = Rack::Attack.throttles.fetch("login/email")
    req = request_for("/login", params: { email: "fan@example.com" })

    RedisCacheOutage.with_rack_attack do
      assert_equal "fan@example.com", rule.block.call(req)
      assert_equal [false] * (rule.limit * 3), Array.new(rule.limit * 3) { rule.matched_by?(req) }
    end
  end

  test "the /mcp helpers answer unverified, uncharged and without raising while Redis is down" do
    authorization = "Bearer tmk_" + "a" * ApiKey::TOKEN_LENGTH
    req = request_for("/mcp")
    req.env["HTTP_AUTHORIZATION"] = authorization

    RedisCacheOutage.with_rack_attack do |swallowed|
      Rack::Attack.mcp_mark_verified(req)
      refute Rack::Attack.mcp_verified?(Rack::Attack::Request.new(req.env.except("mcp.key_verified")))
      refute Rack::Attack.mcp_charge_batch(req, Rack::Attack::MCP_KEY_LIMIT * 2)
      refute_empty connection_errors(swallowed)
    end
  end
end
