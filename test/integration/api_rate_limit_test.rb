require "test_helper"

# [integration] The agent API's own rack-attack tier.
#
# Every other throttle in config/initializers/rack_attack.rb is an allowlist of
# browser paths, so a new route is EXEMPT until someone adds it. The /api/ tier
# is a prefix match so that an endpoint added there is throttled by default —
# which is the property these tests pin, along with what it is keyed on and the
# shape of the 429.
class ApiRateLimitTest < ActionDispatch::IntegrationTest
  def request_for(path, method: "GET", authorization: nil, ip: "203.0.113.9")
    env = Rack::MockRequest.env_for(path, method: method, "REMOTE_ADDR" => ip)
    env["HTTP_AUTHORIZATION"] = authorization if authorization
    Rack::Attack::Request.new(env)
  end

  def discriminator(name, request)
    Rack::Attack.throttles.fetch(name).block.call(request)
  end

  # Rack::Attack is off in the test environment and Rails.cache is a null
  # store; turn the real middleware on, against a real counter, for one block.
  def with_rack_attack
    prior_store = Rack::Attack.cache.store
    Rack::Attack.cache.store = ActiveSupport::Cache::MemoryStore.new
    Rack::Attack.enabled = true
    yield
  ensure
    Rack::Attack.enabled = false
    Rack::Attack.cache.store = prior_store
  end

  # --- what the tier is keyed on -------------------------------------------------

  test "api/key is keyed on a digest of the bearer key, never the key itself" do
    raw = "tmk_" + "a" * ApiKey::TOKEN_LENGTH
    key = discriminator("api/key", request_for("/api/v1/me", authorization: "Bearer #{raw}"))

    assert_equal Digest::SHA256.hexdigest(raw)[0, 32], key
    assert_not_includes key, raw
  end

  test "api/key follows the key, not the address it calls from" do
    auth = "Bearer tmk_" + "a" * ApiKey::TOKEN_LENGTH
    other = "Bearer tmk_" + "b" * ApiKey::TOKEN_LENGTH

    one = discriminator("api/key", request_for("/api/v1/me", authorization: auth, ip: "203.0.113.1"))
    two = discriminator("api/key", request_for("/api/v1/me", authorization: auth, ip: "203.0.113.2"))
    three = discriminator("api/key", request_for("/api/v1/me", authorization: other, ip: "203.0.113.1"))

    assert_equal one, two
    assert_not_equal one, three
  end

  test "a request with no bearer key falls to the per-IP backstop only" do
    request = request_for("/api/v1/me")

    assert_nil discriminator("api/key", request)
    assert_equal "203.0.113.9", discriminator("api/ip", request)
  end

  test "the tier covers any path under /api/, any verb, including ones that do not exist yet" do
    auth = "Bearer tmk_" + "a" * ApiKey::TOKEN_LENGTH

    %w[GET POST PATCH DELETE].each do |verb|
      request = request_for("/api/v1/some/future/endpoint", method: verb, authorization: auth)

      assert discriminator("api/key", request).present?, "#{verb} must be throttled per key"
      assert discriminator("api/ip", request).present?, "#{verb} must be throttled per IP"
    end
  end

  test "the tier does not reach outside /api/" do
    auth = "Bearer tmk_" + "a" * ApiKey::TOKEN_LENGTH

    ["/account", "/contests", "/apiary", "/api"].each do |path|
      request = request_for(path, authorization: auth)

      assert_nil discriminator("api/key", request), "#{path} is not an API path"
      assert_nil discriminator("api/ip", request), "#{path} is not an API path"
    end
  end

  test "the per-key limit is tighter than the per-IP backstop" do
    key = Rack::Attack.throttles.fetch("api/key")
    ip = Rack::Attack.throttles.fetch("api/ip")

    assert_equal [120, 60], [key.limit, key.period.to_i]
    assert_equal [600, 60], [ip.limit, ip.period.to_i]
  end

  test "minting a key is throttled per IP" do
    assert_equal "203.0.113.9", discriminator("api_key_mint/ip", request_for("/account/api_keys", method: "POST"))
    assert_nil discriminator("api_key_mint/ip", request_for("/account/api_keys/1", method: "DELETE"))
  end

  # --- the real middleware ---------------------------------------------------------

  test "the request past the per-key limit is a 429 in the API envelope" do
    limit = Rack::Attack.throttles.fetch("api/key").limit
    headers = { "Authorization" => "Bearer tmk_" + "c" * ApiKey::TOKEN_LENGTH }

    with_rack_attack do
      limit.times do
        get "/api/v1/me", headers: headers
        assert_response :unauthorized
      end
      get "/api/v1/me", headers: headers

      assert_response :too_many_requests
      assert_equal "application/json", response.media_type
      body = JSON.parse(response.body)
      assert_equal "rate_limited", body.dig("error", "code")
      assert body.dig("error", "message").present?
      assert_equal 60, body["retry_after"]
      assert_equal "60", response.headers["Retry-After"]
      assert_nil response.headers["X-RateLimit-Tier"], "that header drives the browser's wait modal"

      # A different key, same address, is still served.
      get "/api/v1/me", headers: { "Authorization" => "Bearer tmk_" + "d" * ApiKey::TOKEN_LENGTH }
      assert_response :unauthorized
    end
  end

  test "a browser-path 429 keeps its existing shape" do
    env = { "rack.attack.matched" => "faucet/ip", "rack.attack.match_data" => { period: 60 }, "PATH_INFO" => "/faucet" }
    status, headers, body = Rack::Attack.throttled_responder.call(Rack::Attack::Request.new(env))

    assert_equal 429, status
    assert_equal "general", headers["X-RateLimit-Tier"]
    assert_equal({ "error" => "Too many requests. Try again later.", "tier" => "general", "retry_after" => 60 },
                 JSON.parse(body.first))
  end
end
