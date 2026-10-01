require "test_helper"

# [unit] AgentMcp::Server: JSON-RPC and the MCP lifecycle, with no HTTP and no
# database. Tools are run by a double, so what is pinned here is the protocol:
# which message gets which answer, at which revision.
class AgentMcp::ServerTest < ActiveSupport::TestCase
  Outcome = Api::V1::Operations::Outcome
  P = AgentMcp::Protocol

  setup do
    @calls = []
    @outcome = Outcome.ok({ "hello" => "world" })
  end

  def server
    AgentMcp::Server.new(run_tool: lambda { |tool, arguments|
      @calls << [tool.name, arguments]
      @outcome.respond_to?(:call) ? @outcome.call : @outcome
    })
  end

  def handle(payload, header: nil)
    server.handle(payload.as_json, version_header: header)
  end

  def request(method, params = nil, id: 1)
    { jsonrpc: "2.0", id: id, method: method, params: params }.compact
  end

  def initialize_with(version)
    handle(request("initialize", { protocolVersion: version, capabilities: {}, clientInfo: { name: "t", version: "0" } }))
  end

  def error_code(reply)
    reply.body.dig(:error, :code)
  end

  # --- initialize -------------------------------------------------------------------

  test "initialize answers each supported revision with that revision" do
    assert_equal %w[2025-03-26 2025-06-18 2025-11-25], P::VERSIONS

    P::VERSIONS.each do |version|
      reply = initialize_with(version)

      assert_equal 200, reply.status
      assert_equal version, reply.body.dig(:result, :protocolVersion)
      assert_equal 1, reply.body[:id]
      assert_equal "2.0", reply.body[:jsonrpc]
    end
  end

  test "initialize answers a revision it does not speak with the latest it does" do
    %w[2024-11-05 2099-01-01 nonsense].each do |version|
      assert_equal "2025-11-25", initialize_with(version).body.dig(:result, :protocolVersion)
    end
  end

  test "initialize declares tools and nothing else, names the server, and carries the instructions" do
    result = initialize_with("2025-11-25").body[:result]

    assert_equal({ tools: { listChanged: false } }, result[:capabilities])
    assert_equal({ name: "turf-monster", version: "1.0.0", title: "Turf Monster" }, result[:serverInfo])
    assert_equal AgentMcp::Instructions::TEXT, result[:instructions]
    assert_equal({ name: "turf-monster", version: "1.0.0" }, initialize_with("2025-03-26").body.dig(:result, :serverInfo))
  end

  test "the instructions say what the game is, the order of the tools, and the three rules" do
    text = AgentMcp::Instructions::TEXT

    AgentMcp::Tools::ALL.each { |tool| assert_includes text, tool.name }
    assert_operator text.index("get_me"), :<, text.index("list_contests")
    assert_operator text.index("get_contest"), :<, text.index("submit_entry")
    assert_match(/CONFIRM IT WITH THE PLAYER before submitting/, text)
    assert_match(/leave allow_usdc false unless the player has told you/, text)
    assert_match(/SAME idempotency_key/, text)
    assert_match(/turf_score/, text)
  end

  test "initialize without a protocolVersion is invalid params" do
    reply = handle(request("initialize", {}))

    assert_equal [200, P::INVALID_PARAMS], [reply.status, error_code(reply)]
  end

  test "initialize is never refused for the version header sent with it" do
    reply = server.handle(request("initialize", { protocolVersion: "2099-01-01" }).as_json, version_header: "2099-01-01")

    assert_equal 200, reply.status
    assert_equal "2025-11-25", reply.body.dig(:result, :protocolVersion)
  end

  # --- the version header -----------------------------------------------------------

  test "a supported version header is accepted and an unsupported one is a 400" do
    P::VERSIONS.each { |version| assert_equal 200, handle(request("ping"), header: version).status }

    %w[2024-11-05 2099-01-01 banana].each do |version|
      reply = handle(request("ping"), header: version)

      assert_equal 400, reply.status
      assert_equal P::INVALID_REQUEST, error_code(reply)
      assert_nil reply.body[:id]
      assert_equal P::VERSIONS, reply.body.dig(:error, :data, :supported)
    end
  end

  test "no version header means 2025-03-26: batches allowed, no structured content" do
    reply = handle([request("ping", id: 1), request("tools/call", { name: "get_me" }, id: 2)])

    assert_equal 200, reply.status
    assert_not reply.body.last[:result].key?(:structuredContent)
  end

  # --- ping, notifications, responses -----------------------------------------------

  test "ping answers an empty result" do
    assert_equal({ jsonrpc: "2.0", id: "abc", result: {} }, handle(request("ping", id: "abc")).body)
  end

  test "a notification is accepted with 202 and no body, whatever it is" do
    %w[notifications/initialized notifications/cancelled notifications/whatever tools/list].each do |method|
      reply = handle({ jsonrpc: "2.0", method: method })

      assert_equal [202, nil], [reply.status, reply.body]
    end
    assert_empty @calls
  end

  test "a response from the client is accepted with 202 and no body" do
    assert_equal 202, handle({ jsonrpc: "2.0", id: 7, result: {} }).status
    assert_equal 202, handle({ jsonrpc: "2.0", id: 7, error: { code: -1, message: "x" } }).status
  end

  # --- malformed messages -----------------------------------------------------------

  test "a message that is not a JSON-RPC request is a 400 invalid request with a null id" do
    ["text", 7, nil, {}, { id: 1, method: "ping" }, { jsonrpc: "1.0", id: 1, method: "ping" },
     { jsonrpc: "2.0", id: 1 }, { jsonrpc: "2.0", id: 1, method: 5 },
     { jsonrpc: "2.0", id: nil, method: "ping" }, { jsonrpc: "2.0", id: 1.5, method: "ping" },
     { jsonrpc: "2.0", id: [1], method: "ping" }].each do |payload|
      reply = server.handle(payload.as_json)

      assert_equal 400, reply.status, payload.inspect
      assert_equal P::INVALID_REQUEST, error_code(reply), payload.inspect
      assert_nil reply.body[:id]
    end
  end

  test "params that are not an object are invalid params, answered to the request's id" do
    reply = handle({ jsonrpc: "2.0", id: 9, method: "tools/list", params: [1] })

    assert_equal [200, P::INVALID_PARAMS, 9], [reply.status, error_code(reply), reply.body[:id]]
  end

  test "a method this server does not have is method not found" do
    %w[resources/list prompts/list logging/setLevel completion/complete nope].each do |method|
      reply = handle(request(method))

      assert_equal [200, P::METHOD_NOT_FOUND], [reply.status, error_code(reply)], method
      assert_equal 1, reply.body[:id]
    end
  end

  test "the parse error is a 400 with code -32700 and a null id" do
    reply = AgentMcp::Server.parse_error

    assert_equal 400, reply.status
    assert_equal({ jsonrpc: "2.0", id: nil, error: { code: -32_700, message: "Parse error: the request body is not valid JSON." } },
                 reply.body)
  end

  # --- tools/list -------------------------------------------------------------------

  test "tools/list returns every tool, in the shape of the revision in the header" do
    reply = handle(request("tools/list"), header: "2025-11-25")

    assert_equal AgentMcp::Tools::ALL.map(&:name), reply.body.dig(:result, :tools).map { |tool| tool[:name] }
    assert_equal AgentMcp::Tools.definitions("2025-11-25"), reply.body.dig(:result, :tools)
    assert_not reply.body[:result].key?(:nextCursor)
    assert_equal AgentMcp::Tools.definitions("2025-03-26"), handle(request("tools/list")).body.dig(:result, :tools)
  end

  # --- tools/call: protocol errors ----------------------------------------------------

  test "an unknown tool is a protocol error, -32602, and runs nothing" do
    reply = handle(request("tools/call", { name: "delete_everything", arguments: {} }))

    assert_equal [200, P::INVALID_PARAMS], [reply.status, error_code(reply)]
    assert_equal "Unknown tool: delete_everything", reply.body.dig(:error, :message)
    assert_empty @calls
  end

  test "tools/call without a name, or with arguments that are not an object, is -32602" do
    [{}, { name: 5 }, { name: "get_me", arguments: [1] }, { name: "get_me", arguments: "x" }].each do |params|
      reply = handle(request("tools/call", params))

      assert_equal P::INVALID_PARAMS, error_code(reply), params.inspect
    end
    assert_empty @calls
  end

  test "arguments left out, or null, are no arguments" do
    handle(request("tools/call", { name: "get_me" }))
    server.handle({ "jsonrpc" => "2.0", "id" => 1, "method" => "tools/call", "params" => { "name" => "get_me", "arguments" => nil } })

    assert_equal [["get_me", {}], ["get_me", {}]], @calls
  end

  test "a tool that crashes is -32603 with no detail" do
    @outcome = -> { raise AgentMcp::Server::ToolCrashed }

    reply = handle(request("tools/call", { name: "get_me" }))

    assert_equal [200, P::INTERNAL_ERROR], [reply.status, error_code(reply)]
    assert_no_match(/ToolCrashed|backtrace/, reply.body.to_json)
  end

  # --- tools/call: results ------------------------------------------------------------

  test "a success is the body as text, and as structuredContent from 2025-06-18" do
    old = handle(request("tools/call", { name: "get_me" }), header: "2025-03-26").body[:result]
    new = handle(request("tools/call", { name: "get_me" }), header: "2025-06-18").body[:result]
    newest = handle(request("tools/call", { name: "get_me" }), header: "2025-11-25").body[:result]

    assert_equal [{ type: "text", text: '{"hello":"world"}' }], old[:content]
    assert_equal false, old[:isError]
    assert_not old.key?(:structuredContent)
    assert_equal({ "hello" => "world" }, new[:structuredContent])
    assert_equal old[:content], new[:content]
    assert_equal new, newest
    assert_equal({ "turfmonster.media/http_status" => 200 }, new[:_meta])
  end

  test "a refusal is isError with the REST envelope, in both forms" do
    @outcome = Outcome.error(:team_locked, "Bills have kicked off.", status: :unprocessable_entity)

    result = handle(request("tools/call", { name: "submit_entry" }), header: "2025-11-25").body[:result]

    envelope = { "error" => { "code" => "team_locked", "message" => "Bills have kicked off." } }
    assert_equal true, result[:isError]
    assert_equal envelope, result[:structuredContent]
    assert_equal [envelope], result[:content].map { |block| JSON.parse(block[:text]) }
    assert_equal({ "turfmonster.media/http_status" => 422 }, result[:_meta])
  end

  test "202 pending is not an error, and says in words to call again with the same key" do
    body = { "entry" => nil, "funding" => { "method" => "token", "token_consumed" => true }, "pending" => true, "retry_after" => 5 }
    @outcome = Outcome.new(status: :accepted, body: body, retry_after: 5)

    result = handle(request("tools/call", { name: "submit_entry" }), header: "2025-11-25").body[:result]

    assert_equal false, result[:isError]
    assert_equal body, result[:structuredContent]
    assert_equal body, JSON.parse(result[:content].first[:text])
    assert_match(/PENDING, NOT A FAILURE.*paid.*in 5 seconds.*SAME idempotency_key/, result[:content].second[:text])
    assert_equal({ "turfmonster.media/http_status" => 202, "turfmonster.media/retry_after" => 5 }, result[:_meta])
  end

  test "409 in progress and 503 are errors that say to retry with the same key" do
    { idempotency_in_progress: [:conflict, 409, 2], chain_unavailable: [:service_unavailable, 503, 10] }.each do |code, (status, http, wait)|
      @outcome = Outcome.error(code, "words", status: status, retry_after: wait)

      result = handle(request("tools/call", { name: "submit_entry" }), header: "2025-11-25").body[:result]

      assert_equal true, result[:isError]
      assert_equal({ "error" => { "code" => code.to_s, "message" => "words", "retry_after" => wait } }, result[:structuredContent])
      assert_match(/RETRY.*in #{wait} seconds.*SAME idempotency_key/, result[:content].second[:text])
      assert_equal({ "turfmonster.media/http_status" => http, "turfmonster.media/retry_after" => wait }, result[:_meta])
    end
  end

  test "a replayed entry says so in _meta, and an ordinary refusal adds no second block" do
    @outcome = Outcome.new(status: :created, body: { "entry" => {} }, replayed: true)
    replay = handle(request("tools/call", { name: "submit_entry" })).body[:result]

    assert_equal({ "turfmonster.media/http_status" => 201, "turfmonster.media/idempotent_replayed" => true }, replay[:_meta])
    assert_equal 1, replay[:content].size

    @outcome = Outcome.error(:no_entry_token, "none", status: :unprocessable_entity)
    assert_equal 1, handle(request("tools/call", { name: "submit_entry" })).body.dig(:result, :content).size
  end

  # --- batches ------------------------------------------------------------------------

  test "a batch answers each request, in order, and skips notifications" do
    reply = handle([request("ping", id: "a"), { jsonrpc: "2.0", method: "notifications/initialized" },
                    request("nope", id: "b"), request("tools/list", id: "c"), "junk"])

    assert_equal 200, reply.status
    assert_equal ["a", "b", "c", nil], reply.body.map { |message| message[:id] }
    assert_equal [nil, P::METHOD_NOT_FOUND, nil, P::INVALID_REQUEST], reply.body.map { |message| message.dig(:error, :code) }
  end

  test "a batch of only notifications and responses is a 202 with no body" do
    reply = handle([{ jsonrpc: "2.0", method: "notifications/initialized" }, { jsonrpc: "2.0", id: 1, result: {} }])

    assert_equal [202, nil], [reply.status, reply.body]
  end

  test "an empty batch, and one over the cap, are a 400 and run nothing" do
    assert_equal [400, P::INVALID_REQUEST], [handle([]).status, error_code(handle([]))]

    crowd = Array.new(P::MAX_BATCH + 1) { |i| request("tools/call", { name: "get_me" }, id: i) }
    reply = handle(crowd)

    assert_equal [400, P::INVALID_REQUEST], [reply.status, error_code(reply)]
    assert_empty @calls
    assert_equal 200, handle(crowd.first(P::MAX_BATCH)).status
  end

  test "a batch is refused at a revision that removed batching" do
    %w[2025-06-18 2025-11-25].each do |version|
      reply = handle([request("ping")], header: version)

      assert_equal [400, P::INVALID_REQUEST], [reply.status, error_code(reply)]
      assert_match(/removed in MCP 2025-06-18/, reply.body.dig(:error, :message))
    end
    assert_equal 200, handle([request("ping")], header: "2025-03-26").status
  end

  test "initialize inside a batch is refused, and the rest of the batch is still answered" do
    reply = handle([request("initialize", { protocolVersion: "2025-03-26" }, id: 1), request("ping", id: 2)])

    assert_equal [P::INVALID_REQUEST, nil], reply.body.map { |message| message.dig(:error, :code) }
    assert_equal [1, 2], reply.body.map { |message| message[:id] }
  end
end
