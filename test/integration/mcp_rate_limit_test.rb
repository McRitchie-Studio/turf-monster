require "test_helper"

# [integration] The /mcp rack-attack tiers (config/initializers/rack_attack.rb).
#
# /mcp sits outside /api/, so the /api/ prefix tier does not reach it and a new
# route is exempt by default. These pin that it is covered, what each tier is
# keyed on, and the property the tiers exist for: players who share Anthropic's
# egress addresses (a claude.ai connector) are limited by their own key and
# never by each other's traffic.
class McpRateLimitTest < ActionDispatch::IntegrationTest
  ANTHROPIC = "160.79.104.10".freeze # inside 160.79.104.0/21
  ELSEWHERE = "203.0.113.9".freeze

  def request_for(path = "/mcp", method: "POST", authorization: nil, ip: ELSEWHERE)
    env = Rack::MockRequest.env_for("/", method: method, "REMOTE_ADDR" => ip)
    env["PATH_INFO"] = path # set directly: env_for reads "//mcp" as a host
    env["HTTP_AUTHORIZATION"] = authorization if authorization
    Rack::Attack::Request.new(env)
  end

  def discriminator(name, request)
    Rack::Attack.throttles.fetch(name).block.call(request)
  end

  def bearer(letter = "a")
    "Bearer tmk_" + letter * ApiKey::TOKEN_LENGTH
  end

  def with_rack_attack
    prior_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.enabled = true
    yield
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.cache.store = prior_store
  end

  def ping(headers)
    post "/mcp", params: '{"jsonrpc":"2.0","id":1,"method":"ping"}', headers: { "Content-Type" => "application/json" }.merge(headers)
  end

  # --- what each tier is keyed on ---------------------------------------------------

  test "mcp/key is keyed on a digest of the bearer key, whatever address it calls from" do
    one = discriminator("mcp/key", request_for(authorization: bearer, ip: ANTHROPIC))
    two = discriminator("mcp/key", request_for(authorization: bearer, ip: ELSEWHERE))

    assert_equal Digest::SHA256.hexdigest("tmk_" + "a" * ApiKey::TOKEN_LENGTH)[0, 32], one
    assert_equal one, two
    assert_not_equal one, discriminator("mcp/key", request_for(authorization: bearer("b"), ip: ANTHROPIC))
    assert_not_includes one, "tmk_"
  end

  test "the limits: 120 a minute per key, 600 per address with a key, 30 per address without" do
    limits = %w[mcp/key mcp/ip mcp/anon_ip].to_h { |name| [name, Rack::Attack.throttles.fetch(name)] }

    assert_equal({ "mcp/key" => [120, 60], "mcp/ip" => [600, 60], "mcp/anon_ip" => [30, 60] },
                 limits.transform_values { |throttle| [throttle.limit, throttle.period.to_i] })
  end

  test "a keyed request from Anthropic's egress range has no per-address limit; from anywhere else it has the backstop" do
    assert_nil discriminator("mcp/ip", request_for(authorization: bearer, ip: ANTHROPIC))
    assert_equal ELSEWHERE, discriminator("mcp/ip", request_for(authorization: bearer, ip: ELSEWHERE))
  end

  test "the egress range is exactly 160.79.104.0/21" do
    inside = %w[160.79.104.0 160.79.104.10 160.79.107.200 160.79.111.255]
    outside = %w[160.79.103.255 160.79.112.0 160.80.104.1 203.0.113.9 127.0.0.1 2607:6bc0::1]

    inside.each { |ip| assert Rack::Attack.mcp_shared_egress?(request_for(ip: ip)), ip }
    outside.each { |ip| assert_not Rack::Attack.mcp_shared_egress?(request_for(ip: ip)), ip }
  end

  test "a request with no bearer key is limited per address, tightly, wherever it comes from" do
    [ANTHROPIC, ELSEWHERE].each do |ip|
      [nil, "Basic abc", "tmk_no_scheme"].each do |authorization|
        request = request_for(authorization: authorization, ip: ip)

        assert_equal ip, discriminator("mcp/anon_ip", request)
        assert_nil discriminator("mcp/key", request)
        assert_nil discriminator("mcp/ip", request)
      end
    end
    assert_nil discriminator("mcp/anon_ip", request_for(authorization: bearer))
  end

  test "every verb on /mcp is counted, the 405s included" do
    %w[GET POST DELETE PUT PATCH].each do |verb|
      assert_equal ELSEWHERE, discriminator("mcp/anon_ip", request_for(method: verb)), verb
      assert discriminator("mcp/key", request_for(method: verb, authorization: bearer)).present?, verb
    end
  end

  # The throttle must match every path the router sends to McpController, or a
  # loop walks around it by adding a slash.
  test "the tiers cover every spelling the router sends to the endpoint, and nothing else" do
    %w[/mcp /mcp/ //mcp /mcp//].each do |path|
      routed = begin
        Rails.application.routes.recognize_path(path, method: :post)[:controller] == "mcp"
      rescue ActionController::RoutingError
        false
      end
      next unless routed

      assert discriminator("mcp/key", request_for(path, authorization: bearer)).present?, "POST #{path} reaches the endpoint unthrottled"
      assert_equal ELSEWHERE, discriminator("mcp/anon_ip", request_for(path)), path
    end
    assert_equal "mcp", Rails.application.routes.recognize_path("/mcp", method: :post)[:controller]

    %w[/mcpx /mcp/tools /api/mcp /account /MCP].each do |path|
      %w[mcp/key mcp/ip mcp/anon_ip].each do |name|
        assert_nil discriminator(name, request_for(path, authorization: name == "mcp/anon_ip" ? nil : bearer)), "#{name} #{path}"
      end
    end
  end

  test "the /api/ tier and the /mcp tier do not reach each other's paths" do
    assert_nil discriminator("api/key", request_for("/mcp", authorization: bearer))
    assert_nil discriminator("api/ip", request_for("/mcp", authorization: bearer))
    assert_nil discriminator("mcp/key", request_for("/api/v1/me", authorization: bearer))
  end

  # --- the real middleware ------------------------------------------------------------

  test "past the per-key limit is a 429 in the API envelope, and a second player on the same Anthropic address is still served" do
    limit = Rack::Attack.throttles.fetch("mcp/key").limit
    busy = { "Authorization" => bearer("c"), "REMOTE_ADDR" => ANTHROPIC }

    with_rack_attack do
      limit.times do
        ping(busy)
        assert_response :unauthorized
      end
      ping(busy)

      assert_response :too_many_requests
      assert_equal "application/json", response.media_type
      body = JSON.parse(response.body)
      assert_equal "rate_limited", body.dig("error", "code")
      assert_equal 60, body["retry_after"]
      assert_equal "60", response.headers["Retry-After"]
      assert_nil response.headers["X-RateLimit-Tier"]

      # The other player, same shared address: not locked out.
      ping("Authorization" => bearer("d"), "REMOTE_ADDR" => ANTHROPIC)
      assert_response :unauthorized
    end
  end

  test "many keys on one Anthropic address are never stopped by the address; elsewhere the backstop stops them" do
    backstop = Rack::Attack.throttles.fetch("mcp/ip").limit

    with_rack_attack do
      (backstop + 5).times do |i|
        ping("Authorization" => "Bearer tmk_#{format('%043d', i)}", "REMOTE_ADDR" => ANTHROPIC)
        assert_response :unauthorized
      end

      backstop.times do |i|
        ping("Authorization" => "Bearer tmk_#{format('%043d', i)}", "REMOTE_ADDR" => ELSEWHERE)
        assert_response :unauthorized
      end
      ping("Authorization" => "Bearer tmk_#{format('%043d', backstop + 1)}", "REMOTE_ADDR" => ELSEWHERE)
      assert_response :too_many_requests
    end
  end

  test "keyless requests are cut off at the tight limit, and a keyed request from the same address is not" do
    limit = Rack::Attack.throttles.fetch("mcp/anon_ip").limit

    with_rack_attack do
      limit.times do
        ping("REMOTE_ADDR" => ANTHROPIC)
        assert_response :unauthorized
      end
      ping("REMOTE_ADDR" => ANTHROPIC)
      assert_response :too_many_requests

      ping("Authorization" => bearer("e"), "REMOTE_ADDR" => ANTHROPIC)
      assert_response :unauthorized
    end
  end
end
