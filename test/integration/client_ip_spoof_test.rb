require "test_helper"

# [integration] WHOSE ADDRESS A REQUEST IS COUNTED AGAINST
# (config/initializers/forwarded_headers.rb).
#
# Every per-IP throttle reads `req.ip`, and geo detection reads
# `request.remote_ip`. Both used to believe a `Forwarded` header the caller
# wrote, because Rack 3 prefers it to X-Forwarded-For and the Heroku router
# passes it through untouched. One header moved a caller to any address they
# liked: a fresh throttle bucket per request, and for /mcp an address inside
# Anthropic's range.
#
# The requests here have the shape production's do: the app is reached from the
# router's private address, and the router has appended the real client to the
# right of X-Forwarded-For. Setting REMOTE_ADDR to a public address, as the
# other rate-limit tests do, cannot see any of this.
class ClientIpSpoofTest < ActionDispatch::IntegrationTest
  include RackAttackClock

  ROUTER = "10.1.2.3".freeze
  CLIENT = "198.51.100.7".freeze
  CLAIMED = "160.79.104.5".freeze # inside Anthropic's egress range

  SPOOFS = {
    "a Forwarded header" => { "HTTP_FORWARDED" => "for=#{CLAIMED}" },
    "a Forwarded header with a proxy chain" => { "HTTP_FORWARDED" => "for=#{CLAIMED};proto=https, for=10.9.9.9" },
    "a quoted IPv6-style Forwarded header" => { "HTTP_FORWARDED" => "for=\"[2607:6bc0::1]\"" },
    "a leftmost X-Forwarded-For entry" => { "HTTP_X_FORWARDED_FOR" => "#{CLAIMED}, #{CLIENT}" },
    "both at once" => { "HTTP_FORWARDED" => "for=#{CLAIMED}", "HTTP_X_FORWARDED_FOR" => "#{CLAIMED}, #{CLIENT}" }
  }.freeze

  def heroku_env(path, method: "POST", **headers)
    env = Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => ROUTER, "HTTP_X_FORWARDED_FOR" => CLIENT)
    env.merge(headers)
  end

  def discriminator(name, env)
    Rack::Attack.throttles.fetch(name).block.call(Rack::Attack::Request.new(env))
  end

  def remote_ip(env)
    seen = nil
    app = lambda do |inner|
      seen = ActionDispatch::Request.new(inner).remote_ip
      [200, {}, []]
    end
    ActionDispatch::RemoteIp.new(app).call(env)
    seen
  end

  # The clock is frozen for the block so its requests count into one bucket
  # (test/support/rack_attack_clock.rb).
  def with_rack_attack(&block)
    prior_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.enabled = true
    in_one_rack_attack_period(&block)
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.cache.store = prior_store
  end

  test "only X-Forwarded-For is read for the client address" do
    assert_equal [:x_forwarded], Rack::Request.forwarded_priority
  end

  test "with no spoof, the address is the one the router appended" do
    env = heroku_env("/login")

    assert_equal CLIENT, Rack::Attack::Request.new(env).ip
    assert_equal CLIENT, remote_ip(env)
  end

  SPOOFS.each do |name, headers|
    test "#{name} does not change the address rack-attack or Rails sees" do
      env = heroku_env("/login", **headers)

      assert_equal CLIENT, Rack::Attack::Request.new(env).ip
      assert_equal CLIENT, remote_ip(env)
    end

    # The tiers that were live before /mcp existed.
    test "#{name} does not move a caller out of their bucket on the existing per-IP tiers" do
      {
        "login/ip" => heroku_env("/login", **headers),
        "wallet_withdraw/ip" => heroku_env("/wallet/withdraw", **headers),
        "magic_link/ip" => heroku_env("/magic_link", **headers),
        "api/ip" => heroku_env("/api/v1/me", method: "GET", **headers),
        "api_key_mint/ip" => heroku_env("/account/api_keys", **headers)
      }.each do |throttle, env|
        assert_equal CLIENT, discriminator(throttle, env), throttle
      end
    end

    test "#{name} does not move a caller into Anthropic's range on /mcp" do
      env = heroku_env("/mcp", **headers, "HTTP_AUTHORIZATION" => "Bearer tmk_#{'a' * ApiKey::TOKEN_LENGTH}")

      assert_equal CLIENT, discriminator("mcp/unverified_ip", env)
      assert_not Rack::Attack.mcp_shared_egress?(Rack::Attack::Request.new(env))
      assert_equal 30, Rack::Attack.throttles.fetch("mcp/unverified_ip").limit.call(Rack::Attack::Request.new(env))
    end
  end

  test "a Forwarded header cannot set the host or the scheme either" do
    env = heroku_env("/login", "HTTP_FORWARDED" => "for=#{CLAIMED};host=evil.example;proto=http",
                               "HTTP_HOST" => "turfmonster.media", "HTTP_X_FORWARDED_PROTO" => "https")
    request = ActionDispatch::Request.new(env)

    assert_equal "turfmonster.media", request.host
    assert_equal "https", request.scheme
  end

  test "a request the router really received from Anthropic's range is still seen as that" do
    env = heroku_env("/mcp", "HTTP_X_FORWARDED_FOR" => "203.0.113.50, #{CLAIMED}")

    assert_equal CLAIMED, Rack::Attack::Request.new(env).ip
    assert Rack::Attack.mcp_shared_egress?(Rack::Attack::Request.new(env))
  end

  # --- through the real middleware ------------------------------------------------------

  test "rotating a spoofed address on every request does not escape the /mcp limit" do
    with_rack_attack do
      statuses = Array.new(31) do |i|
        post "/mcp", params: '{"jsonrpc":"2.0","id":1,"method":"ping"}',
                     headers: { "Content-Type" => "application/json", "REMOTE_ADDR" => ROUTER,
                                "X-Forwarded-For" => "160.79.104.#{i}, #{CLIENT}", "Forwarded" => "for=160.79.105.#{i}",
                                "Authorization" => "Bearer tmk_#{format('%043d', i)}" }
        response.status
      end

      assert_equal [401] * 30 + [429], statuses
    end
  end

  test "rotating a spoofed address on every request does not escape the /api/ backstop" do
    limit = Rack::Attack.throttles.fetch("api/ip").limit

    with_rack_attack do
      statuses = Array.new(limit + 1) do |i|
        get "/api/v1/me", headers: { "REMOTE_ADDR" => ROUTER, "X-Forwarded-For" => CLIENT,
                                     "Forwarded" => "for=192.0.2.#{i % 250}",
                                     "Authorization" => "Bearer tmk_#{format('%043d', i)}" }
        response.status
      end

      assert_equal 429, statuses.last
      assert_equal [401], statuses.first(limit).uniq
    end
  end
end
