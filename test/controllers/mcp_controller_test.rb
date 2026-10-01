require "test_helper"

# [integration] POST /mcp, driven the way a client drives it: initialize, the
# initialized notification, tools/list, then every tool, over real HTTP with a
# real key. What is pinned:
#
#   * each tool returns exactly the JSON its REST endpoint returns;
#   * each failure carries REST's own error code, as isError;
#   * the 401s are HTTP, with WWW-Authenticate, before any JSON-RPC is read;
#   * a frozen account reads and does not write;
#   * submit_entry is as safe as POST /api/v1/contests/:slug/entries: one
#     idempotency key, one token, counted on the chain's own books
#     (test/support/ledger_vault.rb).
#
# The protocol's corners are in test/services/agent_mcp/server_test.rb.
class McpControllerTest < ActionDispatch::IntegrationTest
  include AgentApiTestSupport

  CLIENT_UA = "claude-code/2.0 (mcp)".freeze

  setup do
    @contest = make_onchain!(contests(:one))
    @user = make_managed!(users(:sam))
    @key = mint_api_key(@user)
    @picks = fixture_matchups.map(&:id)
    @vault = LedgerVault.new(tokens: [{ pda: "token-1", consumed: false }])
    @version = "2025-11-25"
    @next_id = 0
  end

  # ── a client ──────────────────────────────────────────────────────────────

  def mcp_headers(key: @key, version: @version, authorization: :key)
    headers = { "User-Agent" => CLIENT_UA, "Content-Type" => "application/json",
                "Accept" => "application/json, text/event-stream" }
    headers["Authorization"] = "Bearer #{key.raw_token}" if authorization == :key && key
    headers["Authorization"] = authorization if authorization.is_a?(String)
    headers["MCP-Protocol-Version"] = version if version
    headers
  end

  def mcp_post(body, **options)
    post "/mcp", params: body.is_a?(String) ? body : JSON.generate(body), headers: mcp_headers(**options)
  end

  def rpc(method, params = nil, **options)
    mcp_post({ jsonrpc: "2.0", id: (@next_id += 1), method: method, params: params }.compact, **options)
  end

  def call_tool(name, arguments = {}, **options)
    on_chain(@vault) { rpc("tools/call", { name: name, arguments: arguments }, **options) }
    assert_response :ok
    json["result"]
  end

  # The tool's JSON, from structuredContent, having checked the text block agrees.
  def tool_json(result)
    assert_equal result["structuredContent"], JSON.parse(result["content"].first["text"])
    result["structuredContent"]
  end

  def assert_tool_error(result, code, status)
    assert_equal true, result["isError"], result.inspect
    assert_equal %w[error], tool_json(result).keys
    assert_equal code, tool_json(result).dig("error", "code")
    assert tool_json(result).dig("error", "message").present?
    assert_equal status, result.dig("_meta", "turfmonster.media/http_status")
  end

  def rest(path, params: {})
    api_get path, params: params
    assert_response :ok
    json
  end

  def submit(picks = @picks, key: "entry-1", **arguments)
    call_tool("submit_entry", { contest_slug: @contest.slug, matchup_ids: picks, idempotency_key: key }.merge(arguments))
  end

  def my_entries
    @contest.entries.where(user: @user)
  end

  def assert_nothing_spent
    assert_empty @vault.tickets
    assert_empty @vault.spent_tokens
    assert_empty my_entries.where.not(status: :cart)
  end

  # ── the handshake ─────────────────────────────────────────────────────────

  test "a client connects: initialize, initialized, tools/list" do
    rpc("initialize", { protocolVersion: "2025-11-25", capabilities: {}, clientInfo: { name: "claude-code", version: "2.0" } },
        version: nil)

    assert_response :ok
    assert_equal "application/json", response.media_type
    assert_equal "no-store", response.headers["Cache-Control"]
    assert_nil response.headers["Mcp-Session-Id"], "stateless: no session is issued"
    result = json["result"]
    assert_equal "2025-11-25", result["protocolVersion"]
    assert_equal({ "tools" => { "listChanged" => false } }, result["capabilities"])
    assert_equal "turf-monster", result.dig("serverInfo", "name")
    assert_match(/CONFIRM IT WITH THE PLAYER/, result["instructions"])

    mcp_post({ jsonrpc: "2.0", method: "notifications/initialized" })
    assert_response :accepted
    assert_empty response.body

    rpc("tools/list")
    assert_response :ok
    assert_equal %w[get_me list_contests get_contest get_leaderboard list_my_entries get_entry submit_entry edit_entry],
                 json.dig("result", "tools").map { |tool| tool["name"] }
    json.dig("result", "tools").each do |tool|
      assert_equal %w[annotations description inputSchema name title], tool.keys.sort
    end
  end

  test "each supported revision is negotiated, and an older client is offered the latest" do
    %w[2025-03-26 2025-06-18 2025-11-25].each do |version|
      rpc("initialize", { protocolVersion: version, capabilities: {}, clientInfo: { name: "c", version: "1" } }, version: nil)
      assert_equal version, json.dig("result", "protocolVersion")
    end

    rpc("initialize", { protocolVersion: "2024-11-05", capabilities: {}, clientInfo: { name: "c", version: "1" } }, version: nil)
    assert_equal "2025-11-25", json.dig("result", "protocolVersion")
  end

  test "ping answers, and a version header the server does not speak is a 400" do
    rpc("ping")
    assert_response :ok
    assert_equal({}, json["result"])

    rpc("ping", version: "2024-11-05")
    assert_response :bad_request
    assert_equal(-32_600, json.dig("error", "code"))
  end

  # Revision 2026-07-28 has no handshake. A client that speaks it and the older
  # revisions (Claude Code 2.1.286) opens with this exact probe, and falls back
  # to `initialize` only when the 400 it gets is NOT one of the modern error
  # codes. Answer with one of those and the client stops falling back.
  test "a 2026-07-28 probe is refused in a way that makes a dual-era client fall back to initialize" do
    probe = { jsonrpc: "2.0", id: "server-discover-probe-1", method: "server/discover",
              params: { _meta: { "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
                                 "io.modelcontextprotocol/clientInfo" => { name: "claude-code", version: "2.1.286" },
                                 "io.modelcontextprotocol/clientCapabilities" => {} } } }

    post "/mcp", params: JSON.generate(probe),
                 headers: mcp_headers(version: "2026-07-28").merge("Mcp-Method" => "server/discover")

    assert_response :bad_request
    assert_not_includes AgentMcp::Protocol::MODERN_ERROR_CODES, json.dig("error", "code")
    assert_equal(-32_600, json.dig("error", "code"))
    assert_equal %w[2025-03-26 2025-06-18 2025-11-25], json.dig("error", "data", "supported")

    # …and the fallback it then makes works, whichever revision it names.
    %w[2026-07-28 2025-11-25].each do |version|
      rpc("initialize", { protocolVersion: version, capabilities: {}, clientInfo: { name: "claude-code", version: "2.1.286" } },
          version: nil)
      assert_response :ok
      assert_equal "2025-11-25", json.dig("result", "protocolVersion")
    end

    # Without the header the probe is an unknown method, also not a modern error.
    mcp_post(probe, version: nil)
    assert_equal(-32_601, json.dig("error", "code"))
  end

  # ── every read tool returns what REST returns ─────────────────────────────

  test "get_me is GET /api/v1/me" do
    on_chain(@vault) { @rest = rest(api_v1_me_path) }

    result = call_tool("get_me")

    assert_equal false, result["isError"]
    assert_equal @rest, tool_json(result)
    assert_equal "managed", tool_json(result).dig("wallet", "kind")
    assert_equal({ "turfmonster.media/http_status" => 200 }, result["_meta"])
  end

  test "list_contests is GET /api/v1/contests, filter and paging included" do
    assert_equal rest(api_v1_contests_path), tool_json(call_tool("list_contests"))
    assert_equal rest(api_v1_contests_path, params: { status: "open", limit: 1, offset: 0 }),
                 tool_json(call_tool("list_contests", { status: "open", limit: 1, offset: 0 }))
    assert_equal 1, tool_json(call_tool("list_contests", { limit: 1 })).dig("pagination", "limit")
  end

  test "get_contest is GET /api/v1/contests/:slug, board and all" do
    result = tool_json(call_tool("get_contest", { contest_slug: @contest.slug }))

    assert_equal rest(api_v1_contest_path(@contest.slug)), result
    assert_equal @picks.sort, result["teams"].map { |team| team["matchup_id"] }.sort & @picks.sort
  end

  test "get_leaderboard is GET /api/v1/contests/:slug/leaderboard" do
    enter!(@user, @contest, fixture_matchups, score: 12.5)
    enter!(users(:alex), @contest, fixture_matchups.first(5) + extra_matchups.first(1), score: 20.0)

    result = tool_json(call_tool("get_leaderboard", { contest_slug: @contest.slug, limit: 10 }))

    assert_equal rest(api_v1_contest_leaderboard_path(@contest.slug), params: { limit: 10 }), result
    assert_equal 1, result["entries"].count { |row| row["mine"] }
    assert_operator result["entries"].size, :>=, 2
  end

  test "list_my_entries is GET /api/v1/entries, and contest_slug is its contest filter" do
    entry = enter!(@user, @contest, fixture_matchups)

    assert_equal rest(api_v1_entries_path), tool_json(call_tool("list_my_entries"))
    filtered = tool_json(call_tool("list_my_entries", { contest_slug: @contest.slug }))
    assert_equal rest(api_v1_entries_path, params: { contest: @contest.slug }), filtered
    assert_equal [entry.slug], filtered["entries"].map { |row| row["slug"] }
  end

  test "get_entry is GET /api/v1/entries/:slug, and another player's entry is not_found" do
    mine = enter!(@user, @contest, fixture_matchups)
    theirs = enter!(users(:alex), @contest, fixture_matchups.first(5) + extra_matchups.first(1))

    assert_equal rest(api_v1_entry_path(mine.slug)), tool_json(call_tool("get_entry", { entry_slug: mine.slug }))
    assert_tool_error call_tool("get_entry", { entry_slug: theirs.slug }), "not_found", 404
  end

  test "before 2025-06-18 a result is text only, and it is the same JSON" do
    result = call_tool("get_contest", { contest_slug: @contest.slug }, version: "2025-03-26")

    assert_not result.key?("structuredContent")
    assert_equal rest(api_v1_contest_path(@contest.slug)), JSON.parse(result["content"].first["text"])
  end

  # ── the writing tools ─────────────────────────────────────────────────────

  test "submit_entry creates and funds an entry, and returns what POST returns" do
    result = submit

    assert_equal false, result["isError"]
    body = tool_json(result)
    assert_equal %w[entry funding], body.keys
    assert_equal({ "method" => "token", "token_consumed" => true }, body["funding"])
    entry = my_entries.sole
    assert entry.active?
    assert_equal rest(api_v1_entry_path(entry.slug))["entry"], body["entry"]
    assert_equal({ "turfmonster.media/http_status" => 201 }, result["_meta"])
    assert_equal 1, @vault.tickets.size
    assert_equal 1, @vault.spent_tokens.size
  end

  test "submit_entry on the same idempotency key replays the first answer and spends one token" do
    @vault.grant_token("token-2")
    first = submit(key: "retry-me")

    second = submit(key: "retry-me")

    assert_equal first["content"], second["content"]
    assert_equal false, second["isError"]
    assert_equal true, second.dig("_meta", "turfmonster.media/idempotent_replayed")
    assert_equal 1, @vault.tickets.size
    assert_equal 1, @vault.spent_tokens.size
    assert_equal 1, my_entries.count
    assert_equal 1, ApiEntryRequest.where(user: @user).count
  end

  test "the idempotency record is REST's: a key spent over MCP replays over REST, and the other way" do
    @vault.grant_token("token-2")
    first = submit(key: "shared-key")

    on_chain(@vault) { api_enter(@contest, @picks, idem: "shared-key") }

    assert_response :created
    assert_equal "true", response.headers["Idempotent-Replayed"]
    assert_equal tool_json(first), json
    assert_equal 1, @vault.spent_tokens.size

    g, = extra_matchups
    other = @picks.first(5) + [g.id]
    on_chain(@vault) { api_enter(@contest, other, idem: "rest-key") }
    assert_response :created
    rest_body = json

    replay = call_tool("submit_entry", { contest_slug: @contest.slug, matchup_ids: other, idempotency_key: "rest-key" })
    assert_equal rest_body, tool_json(replay)
    assert_equal 2, @vault.spent_tokens.size
  end

  test "submit_entry: the same key with different picks is idempotency_key_reused, and spends nothing more" do
    g, = extra_matchups
    @vault.grant_token("token-2")
    submit(key: "one-key")

    assert_tool_error submit(@picks.first(5) + [g.id], key: "one-key"), "idempotency_key_reused", 409
    assert_equal 1, @vault.tickets.size
    assert_equal 1, my_entries.count
  end

  test "submit_entry: a concurrent duplicate is idempotency_in_progress, told to retry, and one token is spent" do
    duplicate = nil
    @vault.grant_token("token-2")
    body = { jsonrpc: "2.0", id: 99, method: "tools/call",
             params: { name: "submit_entry", arguments: { contest_slug: @contest.slug, matchup_ids: @picks, idempotency_key: "same" } } }
    @vault.before_enter = lambda do
      @vault.before_enter = nil
      other = open_session
      other.post "/mcp", params: JSON.generate(body), headers: mcp_headers
      duplicate = JSON.parse(other.response.body)["result"]
    end

    first = submit(key: "same")

    assert_equal false, first["isError"]
    assert_equal true, duplicate["isError"]
    assert_equal "idempotency_in_progress", duplicate.dig("structuredContent", "error", "code")
    assert_equal 2, duplicate.dig("structuredContent", "error", "retry_after")
    assert_equal({ "turfmonster.media/http_status" => 409, "turfmonster.media/retry_after" => 2 }, duplicate["_meta"])
    assert_match(/RETRY.*SAME idempotency_key/, duplicate["content"].second["text"])
    assert_equal 1, @vault.tickets.size
    assert_equal 1, @vault.spent_tokens.size
    assert_equal 1, my_entries.count
  end

  test "submit_entry: a lost answer is chain_unavailable, and the same key then returns the one paid entry" do
    @vault.fail_next_enter = :lost

    lost = submit(key: "lost")

    assert_tool_error lost, "chain_unavailable", 503
    assert_match(/RETRY/, lost["content"].second["text"])

    again = submit(key: "lost")

    assert_equal false, again["isError"]
    assert_equal "active", tool_json(again).dig("entry", "status")
    assert_equal 1, @vault.tickets.size
    assert_equal 1, @vault.spent_tokens.size
    assert_equal 1, my_entries.count
  end

  test "submit_entry: paid but not confirmed is pending, not an error; the same key then returns the entry" do
    boom = ->(*, **) { raise ActiveRecord::StatementInvalid, "simulated post-broadcast DB failure" }
    pending = TransactionLog.stub(:record!, boom) { submit(key: "paid") }

    assert_equal false, pending["isError"]
    assert_equal({ "entry" => nil, "funding" => { "method" => "token", "token_consumed" => true },
                   "pending" => true, "retry_after" => 5 }, tool_json(pending))
    assert_equal({ "turfmonster.media/http_status" => 202, "turfmonster.media/retry_after" => 5 }, pending["_meta"])
    assert_match(/PENDING: PAID, NOT YET ENTERED/, pending["content"].second["text"])

    done = submit(key: "paid")

    assert_equal "active", tool_json(done).dig("entry", "status")
    assert_equal 1, @vault.tickets.size
    assert_equal 1, my_entries.count
  end

  test "submit_entry is token only unless allow_usdc is true" do
    @vault = LedgerVault.new(tokens: [], usdc: 50.0)

    AppFlags.stub(:web2_usdc_entry?, true) do
      assert_tool_error submit(key: "no-token"), "no_entry_token", 422
      assert_nothing_spent
      assert_in_delta 50.0, @vault.usdc_balance

      paid = submit(key: "with-usdc", allow_usdc: true)
      assert_equal({ "method" => "usdc", "token_consumed" => false }, tool_json(paid)["funding"])
    end
  end

  test "submit_entry without an idempotency key, or with a malformed one, is bad_request and records nothing" do
    missing = call_tool("submit_entry", { contest_slug: @contest.slug, matchup_ids: @picks })

    assert_tool_error missing, "bad_request", 400
    assert_match(/idempotency_key argument/, tool_json(missing).dig("error", "message"))

    ["has space", "x" * 256, "", 12_345, ["k"]].each do |bad|
      assert_tool_error submit(key: bad), "bad_request", 400
    end
    assert_nothing_spent
    assert_equal 0, ApiEntryRequest.count
  end

  test "submit_entry refuses with REST's codes and spends nothing" do
    assert_tool_error submit(@picks.first(5)), "invalid_picks", 422
    assert_tool_error call_tool("submit_entry", { contest_slug: "no-such-contest", matchup_ids: @picks, idempotency_key: "k" }),
                      "not_found", 404
    @contest.update!(starts_at: 1.minute.ago)
    assert_tool_error submit(key: "late"), "contest_locked", 422
    assert_nothing_spent
  end

  test "edit_entry replaces the picks and returns what PATCH returns" do
    submit
    entry = my_entries.sole
    g, = extra_matchups
    lineup = @picks.first(5) + [g.id]

    result = call_tool("edit_entry", { entry_slug: entry.slug, matchup_ids: lineup })

    assert_equal false, result["isError"]
    assert_equal rest(api_v1_entry_path(entry.slug)), tool_json(result)
    assert_equal lineup.sort, entry.reload.selections.map(&:slate_matchup_id).sort
    assert_equal 1, @vault.tickets.size, "an edit is not a spend"

    assert_tool_error call_tool("edit_entry", { entry_slug: entry.slug, matchup_ids: lineup.first(2) }), "invalid_picks", 422
    assert_tool_error call_tool("edit_entry", { entry_slug: "no-such-entry", matchup_ids: lineup }), "not_found", 404
  end

  # ── bad arguments ─────────────────────────────────────────────────────────

  test "arguments of the wrong shape are bad_request tool errors in REST's words, never a crash" do
    [
      ["list_contests", { status: "pending" }], ["list_contests", { limit: "ten" }], ["list_contests", { limit: 0 }],
      ["list_contests", { offset: -1 }], ["list_contests", { limit: [1] }], ["list_contests", { limit: 2.5 }],
      ["get_leaderboard", { contest_slug: @contest.slug, offset: { a: 1 } }],
      ["submit_entry", { contest_slug: @contest.slug, matchup_ids: "1,2,3", idempotency_key: "k" }],
      ["submit_entry", { contest_slug: @contest.slug, matchup_ids: [], idempotency_key: "k" }],
      ["submit_entry", { contest_slug: @contest.slug, matchup_ids: [1, "two"], idempotency_key: "k" }],
      ["submit_entry", { contest_slug: @contest.slug, matchup_ids: @picks, idempotency_key: "k", allow_usdc: "true" }],
      ["submit_entry", { contest_slug: @contest.slug, matchup_ids: @picks, idempotency_key: "k", allow_usdc: 1 }]
    ].each do |name, arguments|
      assert_tool_error call_tool(name, arguments), "bad_request", 400
    end
    assert_nothing_spent
    assert_equal 0, ApiEntryRequest.count
  end

  test "an argument the tool does not have, or a required one left out, is a bad_request that says which" do
    wrong_name = call_tool("get_contest", { slug: @contest.slug })
    assert_tool_error wrong_name, "bad_request", 400
    assert_equal "get_contest has no argument named slug. It takes: contest_slug.", tool_json(wrong_name).dig("error", "message")

    missing = call_tool("get_contest")
    assert_tool_error missing, "bad_request", 400
    assert_equal "contest_slug is required.", tool_json(missing).dig("error", "message")

    assert_tool_error call_tool("get_me", { verbose: true }), "bad_request", 400
  end

  test "a slug that cannot name anything is not_found, as it is over REST" do
    [123, "", "a\u0000b", "x" * 300, ["wk4"], { a: 1 }].each do |slug|
      assert_tool_error call_tool("get_contest", { contest_slug: slug }), "not_found", 404
    end
  end

  # ── protocol errors over HTTP ─────────────────────────────────────────────

  test "an unknown method is -32601 and an unknown tool is -32602, both JSON-RPC errors" do
    rpc("resources/list")
    assert_response :ok
    assert_equal(-32_601, json.dig("error", "code"))

    rpc("tools/call", { name: "withdraw_everything", arguments: {} })
    assert_response :ok
    assert_equal(-32_602, json.dig("error", "code"))
    assert_equal "Unknown tool: withdraw_everything", json.dig("error", "message")
    assert_not json.key?("result")
  end

  test "a body that is not JSON is a 400 parse error in JSON-RPC, and echoes none of it" do
    ["{not json", "", "\xFF\xFE", "{\"jsonrpc\":\"2.0\",\"secret\":\"tmk_leak"].each do |body|
      mcp_post(body)

      assert_response :bad_request
      assert_equal({ "jsonrpc" => "2.0", "id" => nil,
                     "error" => { "code" => -32_700, "message" => "Parse error: the request body is not valid JSON." } }, json)
    end
  end

  test "a body over the size cap is refused without being parsed" do
    mcp_post(JSON.generate({ jsonrpc: "2.0", id: 1, method: "ping", params: { pad: "x" * McpController::MAX_BODY_BYTES } }))

    assert_response :bad_request
    assert_equal(-32_700, json.dig("error", "code"))
  end

  test "a message that is not a request is a 400 invalid request" do
    mcp_post({ id: 1, method: "ping" })

    assert_response :bad_request
    assert_equal(-32_600, json.dig("error", "code"))
  end

  # ── batches ───────────────────────────────────────────────────────────────

  test "a 2025-03-26 batch runs each call and answers in order; later revisions refuse a batch" do
    batch = [
      { jsonrpc: "2.0", id: "me", method: "tools/call", params: { name: "get_me", arguments: {} } },
      { jsonrpc: "2.0", method: "notifications/initialized" },
      { jsonrpc: "2.0", id: "c", method: "tools/call", params: { name: "get_contest", arguments: { contest_slug: @contest.slug } } },
      { jsonrpc: "2.0", id: "x", method: "nope" }
    ]

    on_chain(@vault) { mcp_post(batch, version: "2025-03-26") }

    assert_response :ok
    answers = json
    assert_equal %w[me c x], answers.map { |message| message["id"] }
    assert_equal "managed", JSON.parse(answers[0].dig("result", "content", 0, "text")).dig("wallet", "kind")
    assert_equal rest(api_v1_contest_path(@contest.slug)), JSON.parse(answers[1].dig("result", "content", 0, "text"))
    assert_equal(-32_601, answers[2].dig("error", "code"))

    mcp_post(batch, version: "2025-11-25")
    assert_response :bad_request

    mcp_post([{ jsonrpc: "2.0", method: "notifications/initialized" }], version: nil)
    assert_response :accepted
  end

  test "two submits in one batch on one key spend one token" do
    @vault.grant_token("token-2")
    call = lambda do |id|
      { jsonrpc: "2.0", id: id, method: "tools/call",
        params: { name: "submit_entry", arguments: { contest_slug: @contest.slug, matchup_ids: @picks, idempotency_key: "batch-key" } } }
    end

    on_chain(@vault) { mcp_post([call.call(1), call.call(2)], version: "2025-03-26") }

    assert_response :ok
    assert_equal [false, false], json.map { |message| message.dig("result", "isError") }
    assert_equal json[0].dig("result", "content"), json[1].dig("result", "content")
    assert_equal 1, @vault.spent_tokens.size
    assert_equal 1, my_entries.count
  end

  # ── authentication: HTTP 401, before any JSON-RPC ─────────────────────────

  def assert_unauthorized(code)
    assert_response :unauthorized
    assert_equal 'Bearer realm="Turf Monster API"', response.headers["WWW-Authenticate"]
    assert_equal code, json.dig("error", "code")
    assert_not json.key?("jsonrpc")
  end

  test "no key is a 401 with WWW-Authenticate, on initialize as on every request" do
    rpc("initialize", { protocolVersion: "2025-11-25" }, authorization: nil)
    assert_unauthorized "missing_api_key"

    rpc("tools/list", authorization: nil)
    assert_unauthorized "missing_api_key"

    on_chain(@vault) { rpc("tools/call", { name: "submit_entry", arguments: { contest_slug: @contest.slug, matchup_ids: @picks, idempotency_key: "k" } }, authorization: nil) }
    assert_unauthorized "missing_api_key"
    assert_nothing_spent
  end

  test "an unknown, malformed, revoked or expired key is a 401 with its own code" do
    rpc("tools/list", authorization: "Bearer tmk_" + "z" * ApiKey::TOKEN_LENGTH)
    assert_unauthorized "invalid_api_key"

    rpc("tools/list", authorization: "Basic #{Base64.strict_encode64('a:b')}")
    assert_unauthorized "missing_api_key"

    rpc("tools/list", authorization: @key.raw_token)
    assert_unauthorized "missing_api_key"

    expired = mint_api_key(@user)
    expired.update_columns(expires_at: 1.minute.ago)
    rpc("tools/list", key: expired)
    assert_unauthorized "expired_api_key"

    revoked = mint_api_key(@user)
    raw = revoked.raw_token
    revoked.revoke!
    rpc("tools/list", authorization: "Bearer #{raw}")
    assert_unauthorized "revoked_api_key"
  end

  test "the key is not accepted in the URL, the body, or a tool argument" do
    post "/mcp?api_key=#{@key.raw_token}&access_token=#{@key.raw_token}&key=#{@key.raw_token}&token=#{@key.raw_token}",
         params: JSON.generate({ jsonrpc: "2.0", id: 1, method: "tools/list" }), headers: mcp_headers(authorization: nil)
    assert_unauthorized "missing_api_key"

    mcp_post({ jsonrpc: "2.0", id: 1, method: "tools/call", api_key: @key.raw_token,
               params: { name: "get_me", arguments: { api_key: @key.raw_token }, _meta: { authorization: "Bearer #{@key.raw_token}" } } },
             authorization: nil)
    assert_unauthorized "missing_api_key"
  end

  # ── the write gates ───────────────────────────────────────────────────────

  test "a frozen account reads through every read tool and is refused by both writing tools" do
    entry = enter!(@user, @contest, fixture_matchups)
    @user.freeze_for_payment_risk!(reason: "test")

    rpc("tools/list")
    assert_response :ok

    reads = {
      "get_me" => {}, "list_contests" => {}, "get_contest" => { contest_slug: @contest.slug },
      "get_leaderboard" => { contest_slug: @contest.slug }, "list_my_entries" => {}, "get_entry" => { entry_slug: entry.slug }
    }
    reads.each do |name, arguments|
      assert_equal false, call_tool(name, arguments)["isError"], "#{name} must stay readable for a frozen account"
    end
    assert_equal true, tool_json(call_tool("get_me")).dig("account", "frozen")
    assert_equal false, tool_json(call_tool("get_entry", { entry_slug: entry.slug })).dig("entry", "editable")

    g, = extra_matchups
    assert_tool_error submit(@picks.first(5) + [g.id], key: "frozen"), "account_frozen", 403
    assert_tool_error call_tool("edit_entry", { entry_slug: entry.slug, matchup_ids: @picks.first(5) + [g.id] }), "account_frozen", 403

    assert_empty @vault.tickets
    assert_empty @vault.spent_tokens
    assert_equal 0, ApiEntryRequest.count
    assert_equal @picks.sort, entry.reload.selections.map(&:slate_matchup_id).sort
  end

  test "the registry's write flag is what the gate reads: every writing tool is refused, every read is not" do
    @user.freeze_for_payment_risk!(reason: "test")

    AgentMcp::Tools::ALL.each do |tool|
      result = call_tool(tool.name, {})
      code = result.dig("structuredContent", "error", "code")

      assert_equal tool.writes?, code == "account_frozen", "#{tool.name}: #{code.inspect}"
    end
  end

  test "with the age gate on, an unverified player reads and is refused by the writing tools until verified" do
    AppFlags.stub :age_gate?, true do
      assert_equal false, call_tool("get_contest", { contest_slug: @contest.slug })["isError"]
      assert_tool_error submit(key: "minor"), "age_verification_required", 403
      assert_nothing_spent

      @user.update!(age_attested_at: Time.current)
      assert_equal false, submit(key: "minor")["isError"]
    end
  end

  # ── the transport ─────────────────────────────────────────────────────────

  test "GET, DELETE, PUT and PATCH are 405 with Allow: POST, key or no key" do
    %i[get delete put patch].each do |verb|
      send(verb, "/mcp", headers: { "Accept" => "text/event-stream", "User-Agent" => CLIENT_UA })

      assert_response :method_not_allowed
      assert_equal "POST", response.headers["Allow"]
      assert_equal(-32_600, json.dig("error", "code"))
      assert_equal "2.0", json["jsonrpc"]
    end

    get "/mcp", headers: mcp_headers
    assert_response :method_not_allowed
  end

  test "/mcp is the only spelling" do
    %w[/mcp.json /mcp/tools /api/mcp].each do |path|
      post path, params: "{}", headers: mcp_headers
      assert_response :not_found
    end
  end

  test "a request carrying a foreign Origin is a 403; this site's own, or none, is served" do
    post "/mcp", params: JSON.generate({ jsonrpc: "2.0", id: 1, method: "ping" }),
                 headers: mcp_headers.merge("Origin" => "https://evil.example")
    assert_response :forbidden
    assert_equal(-32_600, json.dig("error", "code"))

    post "/mcp", params: JSON.generate({ jsonrpc: "2.0", id: 1, method: "ping" }),
                 headers: mcp_headers.merge("Origin" => "http://www.example.com")
    assert_response :ok
  end

  test "no user agent and no Accept header are needed" do
    post "/mcp", params: JSON.generate({ jsonrpc: "2.0", id: 1, method: "ping" }),
                 headers: { "Authorization" => "Bearer #{@key.raw_token}", "Content-Type" => "application/json" }

    assert_response :ok
  end
end
