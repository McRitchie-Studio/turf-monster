require "test_helper"
require "socket"

# [integration] How the two hub callers authenticate, over a real socket to a stub
# hub: with STUDIO_RUNTIME_KEY the key is the bearer and no auth exchange is made;
# while it is unset the shared secret is exchanged, as before. Neither value is
# ever in an error.
class Studio::HubCredentialTest < ActiveSupport::TestCase
  KEY = "runtime-key-value".freeze
  SECRET = "shared-secret-value".freeze

  setup do
    @game = games(:past_game)
    @game.update!(home_score: 24, away_score: 17, status_detail: "Final", season_year: 2026, season_type: 2, week: 3)
    SyncCursor.delete_all
    @saved = [ Studio::HubCredential::KEY_ENV, Studio::HubCredential::SECRET_ENV ].to_h { |k| [ k, ENV[k] ] }
    @saved.each_key { |k| ENV.delete(k) }
    @requests = []
    @refuse = nil
    @server = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
    @base = "http://127.0.0.1:#{@server.addr[1]}"
  end

  teardown do
    @server.close
    @thread.join(1)
    @saved.each { |k, v| v.nil? ? ENV.delete(k) : ENV[k] = v }
  end

  # The stub hub: records every request, answers `@refuse` (a status line) to any
  # call carrying the runtime key, and 200 to the rest.
  def serve
    loop do
      client = @server.accept
      method, path = client.gets.to_s.split(" ")
      headers = {}
      while (line = client.gets) && line != "\r\n"
        name, value = line.split(":", 2)
        headers[name.strip.downcase] = value.to_s.strip
      end
      client.read(headers["content-length"].to_i) if headers["content-length"]
      @requests << { method: method, path: path.to_s.split("?").first, bearer: headers["authorization"], caller: headers["x-agent-caller"] }
      status, payload = answer(path.to_s, headers["authorization"])
      client.write("HTTP/1.1 #{status}\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF, Errno::ECONNRESET
    nil
  end

  def answer(path, bearer)
    return [ @refuse, { error: "a client session reaches no board endpoint" }.to_json ] if @refuse && bearer == "Bearer #{KEY}"
    return [ "200 OK", { token: "exchanged-token" }.to_json ] if path == "/api/v1/auth"
    return [ "201 Created", { data: { slug: "content-abc" } }.to_json ] if path == "/api/v1/game_recaps"

    [ "200 OK", { data: [], meta: { more: false } }.to_json ]
  end

  def paths = @requests.map { |r| "#{r[:method]} #{r[:path]}" }

  test "configured? follows either credential" do
    assert_not Studio::HubCredential.configured?
    assert_not Studio::PushGameRecap.configured?
    assert_not Studio::SyncAthletes.configured?

    ENV["AGENT_API_SECRET"] = SECRET
    assert Studio::PushGameRecap.configured?
    ENV.delete("AGENT_API_SECRET")
    ENV["STUDIO_RUNTIME_KEY"] = KEY
    assert Studio::PushGameRecap.configured?
    assert Studio::SyncAthletes.configured?
    ENV["STUDIO_RUNTIME_KEY"] = "  "
    assert_not Studio::HubCredential.configured?, "a blank key is no key"
  end

  test "the recap push presents the runtime key and makes no auth exchange" do
    ENV["STUDIO_RUNTIME_KEY"] = KEY
    ENV["AGENT_API_SECRET"] = SECRET # the key wins while both are set

    Studio::PushGameRecap.new(@game, base_url: @base).call

    assert_equal [ "POST /api/v1/game_recaps" ], paths
    assert_equal [ "Bearer #{KEY}", "turf-monster/push_game_recap" ], @requests.first.values_at(:bearer, :caller)
  end

  test "the athlete sync presents the runtime key and makes no auth exchange" do
    ENV["STUDIO_RUNTIME_KEY"] = KEY

    result = Studio::SyncAthletes.new(base_url: @base).call

    assert_equal "ok", result.status
    assert_equal [ "GET /api/v1/athletes" ], paths
    assert_equal [ "Bearer #{KEY}", "turf-monster/sync_athletes" ], @requests.first.values_at(:bearer, :caller)
  end

  test "with no runtime key both callers exchange the shared secret, as before" do
    ENV["AGENT_API_SECRET"] = SECRET

    Studio::PushGameRecap.new(@game, base_url: @base).call
    Studio::SyncAthletes.new(base_url: @base).call

    assert_equal [ "POST /api/v1/auth", "POST /api/v1/game_recaps", "POST /api/v1/auth", "GET /api/v1/athletes" ], paths
    assert_equal [ nil, "Bearer exchanged-token", nil, "Bearer exchanged-token" ], @requests.map { |r| r[:bearer] }
    assert_equal %w[turf-monster/push_game_recap turf-monster/sync_athletes], @requests.map { |r| r[:caller] }.uniq
  end

  test "a hub that refuses the key fails the call without echoing the key or falling back to the secret" do
    ENV["STUDIO_RUNTIME_KEY"] = KEY
    ENV["AGENT_API_SECRET"] = SECRET
    @refuse = "403 Forbidden"

    error = assert_raises(Studio::PushGameRecap::Error) { Studio::PushGameRecap.new(@game, base_url: @base).call }
    assert_match(/returned 403/, error.message)
    assert_not_includes error.message, KEY

    result = Studio::SyncAthletes.new(base_url: @base).call
    assert_equal "failed", result.status
    assert_not_includes SyncCursor.for("studio_athletes").attributes.values.join(" "), KEY
    assert_equal [ "POST /api/v1/game_recaps", "GET /api/v1/athletes" ], paths, "no silent return to the shared secret"
  end

  test "with neither credential nothing reaches the network" do
    assert_raises(Studio::PushGameRecap::Error) { Studio::PushGameRecap.new(@game, base_url: @base).call }
    assert_equal "skipped", Studio::SyncAthletes.new(base_url: @base).call.status
    assert_empty @requests
  end
end
