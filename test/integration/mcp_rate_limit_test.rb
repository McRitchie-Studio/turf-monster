require "test_helper"

# [integration] The /mcp rack-attack tiers (config/initializers/rack_attack.rb).
#
# /mcp sits outside /api/, so the /api/ prefix tier does not reach it and a new
# route is exempt by default. These pin that it is covered, what each tier is
# keyed on, and the two properties the tiers exist for:
#
#   * a PLAYER is limited by their key and never by the address they call from,
#     so players who share Anthropic's egress addresses (a claude.ai connector)
#     cannot lock each other out;
#   * a request that has not shown it is a player (no key, or a key that has
#     never authenticated here) is limited per address, tightly, and a made-up
#     key does not buy its way out of that.
#
# Whose address a request is counted against is test/integration/client_ip_spoof_test.rb.
class McpRateLimitTest < ActionDispatch::IntegrationTest
  include AgentApiTestSupport

  ANTHROPIC = "160.79.104.10".freeze # inside 160.79.104.0/21
  ELSEWHERE = "203.0.113.9".freeze

  def request_for(path = "/mcp", method: "POST", authorization: nil, ip: ELSEWHERE)
    env = Rack::MockRequest.env_for("/", method: method, "REMOTE_ADDR" => ip)
    env["PATH_INFO"] = path # set directly: env_for reads "//mcp" as a host
    env["HTTP_AUTHORIZATION"] = authorization if authorization
    Rack::Attack::Request.new(env)
  end

  def throttle(name)
    Rack::Attack.throttles.fetch(name)
  end

  def discriminator(name, request)
    throttle(name).block.call(request)
  end

  def bearer(letter = "a")
    "Bearer tmk_" + letter * ApiKey::TOKEN_LENGTH
  end

  def digest(authorization)
    Digest::SHA256.hexdigest(authorization.delete_prefix("Bearer "))[0, 32]
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

  def mark_verified(authorization)
    Rack::Attack.cache.write(Rack::Attack.mcp_verified_cache_key(digest(authorization)), 1, 60)
  end

  # Headers as a hash, or written out: ping("Authorization" => …, "REMOTE_ADDR" => …).
  def ping(headers = {}, body: '{"jsonrpc":"2.0","id":1,"method":"ping"}', **more)
    post "/mcp", params: body, headers: { "Content-Type" => "application/json" }.merge(headers, more)
  end

  # --- what each tier is keyed on ---------------------------------------------------

  test "the tiers are mcp/key and mcp/unverified_ip, and no per-address tier is left for players" do
    assert_equal %w[mcp/key mcp/unverified_ip], Rack::Attack.throttles.keys.grep(%r{\Amcp/}).sort
    assert_equal [120, 60], [throttle("mcp/key").limit, throttle("mcp/key").period.to_i]
    assert_equal 60, throttle("mcp/unverified_ip").period.to_i
  end

  test "mcp/key is keyed on a digest of the bearer key, whatever address it calls from" do
    one = discriminator("mcp/key", request_for(authorization: bearer, ip: ANTHROPIC))
    two = discriminator("mcp/key", request_for(authorization: bearer, ip: ELSEWHERE))

    assert_equal digest(bearer), one
    assert_equal one, two
    assert_not_equal one, discriminator("mcp/key", request_for(authorization: bearer("b"), ip: ANTHROPIC))
    assert_not_includes one, "tmk_"
  end

  test "a request with no bearer key counts against its address" do
    [ANTHROPIC, ELSEWHERE].each do |ip|
      [nil, "Basic abc", "tmk_no_scheme"].each do |authorization|
        request = request_for(authorization: authorization, ip: ip)

        assert_equal ip, discriminator("mcp/unverified_ip", request)
        assert_nil discriminator("mcp/key", request)
      end
    end
  end

  test "a bearer-shaped key that has never authenticated counts against its address; one that has does not" do
    with_rack_attack do
      [ANTHROPIC, ELSEWHERE].each do |ip|
        assert_equal ip, discriminator("mcp/unverified_ip", request_for(authorization: bearer("u"), ip: ip)),
                     "a made-up key must not escape the per-address tier"
      end

      mark_verified(bearer("v"))

      [ANTHROPIC, ELSEWHERE].each do |ip|
        assert_nil discriminator("mcp/unverified_ip", request_for(authorization: bearer("v"), ip: ip)),
                   "a player is never limited by address"
      end
    end
  end

  test "the unverified limit is 30 a minute, and 300 inside Anthropic's range" do
    limit = throttle("mcp/unverified_ip").limit

    assert_equal 30, limit.call(request_for(ip: ELSEWHERE))
    assert_equal 300, limit.call(request_for(ip: ANTHROPIC))
  end

  test "the egress range is exactly 160.79.104.0/21" do
    inside = %w[160.79.104.0 160.79.104.10 160.79.107.200 160.79.111.255]
    outside = %w[160.79.103.255 160.79.112.0 160.80.104.1 203.0.113.9 127.0.0.1 2607:6bc0::1]

    inside.each { |ip| assert Rack::Attack.mcp_shared_egress?(request_for(ip: ip)), ip }
    outside.each { |ip| assert_not Rack::Attack.mcp_shared_egress?(request_for(ip: ip)), ip }
  end

  test "every verb on /mcp is counted, the 405s included" do
    %w[GET POST DELETE PUT PATCH].each do |verb|
      assert_equal ELSEWHERE, discriminator("mcp/unverified_ip", request_for(method: verb)), verb
      assert discriminator("mcp/key", request_for(method: verb, authorization: bearer)).present?, verb
    end
  end

  # The throttle must match every path the router sends to McpController, or a
  # loop walks around it by adding a slash.
  test "the tiers cover every spelling of the path, and nothing else" do
    assert_equal "mcp", Rails.application.routes.recognize_path("/mcp", method: :post)[:controller]

    %w[/mcp /mcp/ //mcp /mcp//].each do |path|
      assert discriminator("mcp/key", request_for(path, authorization: bearer)).present?, "POST #{path} is unthrottled"
      assert_equal ELSEWHERE, discriminator("mcp/unverified_ip", request_for(path)), path
    end

    %w[/mcpx /mcp/tools /api/mcp /account /MCP].each do |path|
      assert_nil discriminator("mcp/key", request_for(path, authorization: bearer)), path
      assert_nil discriminator("mcp/unverified_ip", request_for(path)), path
    end
  end

  test "the /api/ tier and the /mcp tier do not reach each other's paths" do
    assert_nil discriminator("api/key", request_for("/mcp", authorization: bearer))
    assert_nil discriminator("api/ip", request_for("/mcp", authorization: bearer))
    assert_nil discriminator("mcp/key", request_for("/api/v1/me", authorization: bearer))
    assert_nil discriminator("mcp/unverified_ip", request_for("/api/v1/me"))
  end

  # --- the real middleware ------------------------------------------------------------

  test "a different made-up key on every request is cut off at the unverified limit" do
    with_rack_attack do
      30.times do |i|
        ping("Authorization" => "Bearer tmk_#{format('%043d', i)}", "REMOTE_ADDR" => ELSEWHERE)
        assert_response :unauthorized
      end
      ping("Authorization" => "Bearer tmk_#{format('%043d', 999)}", "REMOTE_ADDR" => ELSEWHERE)

      assert_response :too_many_requests
      assert_equal "application/json", response.media_type
      body = JSON.parse(response.body)
      assert_equal "rate_limited", body.dig("error", "code")
      assert_equal 60, body["retry_after"]
      assert_equal "60", response.headers["Retry-After"]
      assert_nil response.headers["X-RateLimit-Tier"]
    end
  end

  test "keyless requests are cut off at the same limit" do
    with_rack_attack do
      30.times do
        ping("REMOTE_ADDR" => ELSEWHERE)
        assert_response :unauthorized
      end
      ping("REMOTE_ADDR" => ELSEWHERE)
      assert_response :too_many_requests
    end
  end

  test "a real key is marked on its first request and is then untouched by a flood from its own address" do
    key = mint_api_key(users(:sam))
    player = { "Authorization" => "Bearer #{key.raw_token}", "REMOTE_ADDR" => ANTHROPIC }

    with_rack_attack do
      ping(player)
      assert_response :ok
      assert Rack::Attack.cache.read(Rack::Attack.mcp_verified_cache_key(digest("Bearer #{key.raw_token}"))).present?

      # Made-up keys from the same shared address, past its 300.
      301.times { |i| ping("Authorization" => "Bearer tmk_#{format('%043d', i)}", "REMOTE_ADDR" => ANTHROPIC) }
      assert_response :too_many_requests

      ping(player)
      assert_response :ok, "a player already seen must not be limited by the address they share"
    end
  end

  test "a made-up key is never marked" do
    with_rack_attack do
      ping("Authorization" => bearer("m"), "REMOTE_ADDR" => ELSEWHERE)

      assert_response :unauthorized
      assert_nil Rack::Attack.cache.read(Rack::Attack.mcp_verified_cache_key(digest(bearer("m"))))
    end
  end

  test "a player past the per-key limit is a 429, and a second player on the same Anthropic address is still served" do
    one = mint_api_key(users(:sam))
    two = mint_api_key(users(:alex))
    busy = { "Authorization" => "Bearer #{one.raw_token}", "REMOTE_ADDR" => ANTHROPIC }

    with_rack_attack do
      120.times do
        ping(busy)
        assert_response :ok
      end
      ping(busy)
      assert_response :too_many_requests

      ping("Authorization" => "Bearer #{two.raw_token}", "REMOTE_ADDR" => ANTHROPIC)
      assert_response :ok
    end
  end

  # --- batches ------------------------------------------------------------------------

  test "a batch is charged one request per message against the key" do
    key = mint_api_key(users(:sam))
    headers = { "Authorization" => "Bearer #{key.raw_token}", "REMOTE_ADDR" => ELSEWHERE }
    batch = JSON.generate(Array.new(10) { |i| { jsonrpc: "2.0", id: i, method: "ping" } })

    with_rack_attack do
      12.times do
        ping(headers, body: batch)
        assert_response :ok
      end

      # 12 batches of 10 are the whole 120. The thirteenth runs nothing.
      ping(headers, body: batch)
      assert_response :too_many_requests
      assert_equal "rate_limited", JSON.parse(response.body).dig("error", "code")
      assert_equal "60", response.headers["Retry-After"]

      ping(headers)
      assert_response :too_many_requests
    end
  end

  test "a batch that would cross the limit is refused whole and runs none of its messages" do
    key = mint_api_key(users(:sam))
    headers = { "Authorization" => "Bearer #{key.raw_token}", "REMOTE_ADDR" => ELSEWHERE }
    calls = 0
    counting = lambda do |*, **|
      calls += 1
      Api::V1::Operations::Outcome.ok({})
    end

    with_rack_attack do
      115.times { ping(headers) }
      batch = JSON.generate(Array.new(10) { |i| { jsonrpc: "2.0", id: i, method: "tools/call", params: { name: "list_contests" } } })

      Api::V1::Operations::ListContests.stub(:call, counting) { ping(headers, body: batch) }

      assert_response :too_many_requests
      assert_equal 0, calls
    end
  end
end
