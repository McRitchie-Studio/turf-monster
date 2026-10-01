# The MCP server: JSON-RPC 2.0 messages in, JSON-RPC messages out. No HTTP, no
# database and no authentication here; McpController does those and hands this
# class a parsed body and a way to run a tool.
#
#   server = AgentMcp::Server.new(run_tool: ->(tool, arguments) { … an Outcome … })
#   reply  = server.handle(parsed_json, version_header: request.headers["MCP-Protocol-Version"])
#   reply.status  # 200, 202 or 400
#   reply.body    # a Hash, an Array (batch), or nil for 202
#
# STATELESS. There is no session and no stream: every request is answered with
# one application/json body, which the Streamable HTTP transport allows ("the
# server MUST either return Content-Type: text/event-stream […] or
# Content-Type: application/json"). No MCP-Session-Id is issued, so a client
# sends none. Nothing is remembered between requests, `initialize` included:
# the revision a client negotiated reaches later requests in the
# MCP-Protocol-Version header (AgentMcp::Protocol::HEADER_ABSENT when it does
# not), and every request authenticates on its own.
#
# METHODS: initialize, ping, tools/list, tools/call. Any notification is
# accepted and ignored (notifications/initialized, notifications/cancelled).
# Anything else is -32601. Resources, prompts, logging and completions are not
# declared in the capabilities and are not answered.
#
# ERRORS, by the specification's two kinds (server/tools, "Error Handling"):
#
#   protocol error   a JSON-RPC `error`: a body that is not JSON (-32700), a
#                    message that is not a JSON-RPC request (-32600), a method
#                    this server does not have (-32601), a tool it does not
#                    have or `arguments` that is not an object (-32602), a
#                    crash (-32603).
#   tool error       a RESULT with `isError: true`: everything the tool itself
#                    refuses, an argument of the wrong type included, in the
#                    agent API's own error envelope (AgentMcp::ToolResult).
module AgentMcp
  class Server
    include Protocol

    Reply = Struct.new(:status, :body)

    # Raised by `run_tool` when a tool failed in a way nobody planned. The
    # caller has already logged it; the client hears -32603 and no detail.
    class ToolCrashed < StandardError; end

    SERVER_INFO = { name: "turf-monster", version: "1.0.0" }.freeze
    SERVER_TITLE = "Turf Monster".freeze

    def initialize(run_tool:)
      @run_tool = run_tool
    end

    def handle(payload, version_header: nil)
      version = version_header.presence || HEADER_ABSENT
      # `initialize` is where a version is chosen, so it is never refused for
      # the header a client happens to send with it.
      unless initialize_request?(payload) || Protocol.supported?(version)
        return invalid("Unsupported MCP-Protocol-Version: #{version.to_s[0, 40]}.", data: { supported: VERSIONS })
      end

      payload.is_a?(Array) ? handle_batch(payload, version) : handle_single(payload, version)
    end

    # A body that could not be parsed at all.
    def self.parse_error
      Reply.new(400, error_message(nil, PARSE_ERROR, "Parse error: the request body is not valid JSON."))
    end

    def self.error_message(id, code, message, data: nil)
      { jsonrpc: "2.0", id: id, error: { code: code, message: message, data: data }.compact }
    end

    private

    def initialize_request?(payload)
      payload.is_a?(Hash) && payload["method"] == "initialize"
    end

    def handle_single(message, version)
      response = respond_to_message(message, version)
      return Reply.new(202, nil) if response.nil?

      Reply.new(malformed?(response) ? 400 : 200, response)
    end

    # JSON-RPC batches exist in revision 2025-03-26 only; 2025-06-18 removed
    # them ("the body of the POST request MUST be a single JSON-RPC request,
    # notification, or response").
    def handle_batch(messages, version)
      return invalid("JSON-RPC batches were removed in MCP 2025-06-18. Send one message per request.") unless Protocol.batching?(version)
      return invalid("An empty batch is not a request.") if messages.empty?
      return invalid("A batch may hold at most #{MAX_BATCH} messages.") if messages.size > MAX_BATCH

      responses = messages.filter_map { |message| respond_to_message(message, version, batched: true) }
      responses.empty? ? Reply.new(202, nil) : Reply.new(200, responses)
    end

    def invalid(message, data: nil)
      Reply.new(400, error(nil, INVALID_REQUEST, message, data: data))
    end

    def malformed?(response)
      response.dig(:error, :code) == INVALID_REQUEST && response[:id].nil?
    end

    # nil when the message wants no response: a notification, or a response to
    # a request this server never sent.
    def respond_to_message(message, version, batched: false)
      return error(nil, INVALID_REQUEST, "A message must be a JSON object.") unless message.is_a?(Hash)
      return error(nil, INVALID_REQUEST, 'jsonrpc must be "2.0".') unless message["jsonrpc"] == "2.0"

      unless message.key?("method")
        return nil if message.key?("result") || message.key?("error")

        return error(nil, INVALID_REQUEST, "A request needs a method.")
      end

      method = message["method"]
      return error(nil, INVALID_REQUEST, "method must be a string.") unless method.is_a?(String)
      return nil unless message.key?("id") # a notification: never answered

      id = message["id"]
      # MCP narrows JSON-RPC here: an id is a string or an integer, never null.
      return error(nil, INVALID_REQUEST, "id must be a string or an integer.") unless id.is_a?(String) || id.is_a?(Integer)

      params = message.fetch("params", {})
      return error(id, INVALID_PARAMS, "params must be an object.") unless params.is_a?(Hash)

      respond_to_request(id, method, params, version, batched: batched)
    end

    def respond_to_request(id, method, params, version, batched:)
      case method
      when "initialize"
        # 2025-03-26 basic/lifecycle: "The initialize request MUST NOT be part
        # of a JSON-RPC batch".
        return error(id, INVALID_REQUEST, "initialize may not be part of a batch.") if batched

        start(id, params)
      when "ping" then result(id, {})
      when "tools/list" then result(id, { tools: Tools.definitions(version) })
      when "tools/call" then call_tool(id, params, version)
      else error(id, METHOD_NOT_FOUND, "Method not found: #{method[0, 80]}")
      end
    end

    # Version negotiation (basic/lifecycle): answer with the client's revision
    # when this server speaks it, otherwise with the latest it does speak, and
    # leave it to the client to disconnect if that will not do.
    def start(id, params)
      requested = params["protocolVersion"]
      return error(id, INVALID_PARAMS, "protocolVersion is required.") unless requested.is_a?(String)

      version = Protocol.supported?(requested) ? requested : LATEST
      server_info = Protocol.titles?(version) ? SERVER_INFO.merge(title: SERVER_TITLE) : SERVER_INFO

      result(id, {
               protocolVersion: version,
               capabilities: { tools: { listChanged: false } },
               serverInfo: server_info,
               instructions: Instructions::TEXT
             })
    end

    def call_tool(id, params, version)
      name = params["name"]
      return error(id, INVALID_PARAMS, "tools/call needs the name of a tool.") unless name.is_a?(String)

      tool = Tools.find(name)
      return error(id, INVALID_PARAMS, "Unknown tool: #{name[0, 80]}") if tool.nil?

      arguments = params.fetch("arguments", {}) || {}
      return error(id, INVALID_PARAMS, "arguments must be an object.") unless arguments.is_a?(Hash)

      result(id, ToolResult.render(@run_tool.call(tool, arguments), version: version))
    rescue ToolCrashed
      error(id, INTERNAL_ERROR, "Something went wrong on our side. For submit_entry, retry with the same idempotency_key.")
    end

    def result(id, value)
      { jsonrpc: "2.0", id: id, result: value }
    end

    def error(id, code, message, data: nil)
      self.class.error_message(id, code, message, data: data)
    end
  end
end
