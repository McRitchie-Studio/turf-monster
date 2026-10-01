# POST /mcp — the agent API as a remote MCP server (docs/AGENT_API.md, "MCP"),
# so a chat client with no way to make HTTP requests of its own can play
# through a connector.
#
# Three layers, and this one is the thinnest:
#
#   McpController        HTTP: the Origin check, the bearer key, the body, the
#                        write gates, and which player a tool runs for.
#   AgentMcp::Server     the protocol: JSON-RPC, versions, tools/list, tools/call.
#   Api::V1::Operations  the work, shared with /api/v1. No rule of the game is
#                        written here or in AgentMcp.
#
# ActionController::API with ApiKeyAuthentication, exactly as
# Api::V1::BaseController is, and for the same reasons. It is not a subclass of
# that controller because it sits outside /api and answers in JSON-RPC.
#
# AUTHENTICATION is `Authorization: Bearer tmk_…` on EVERY request, `initialize`
# included: there is no session, so no request is trusted for what an earlier
# one proved. A missing or bad key is an HTTP 401 with WWW-Authenticate before
# any JSON-RPC is read. The key is read from that header and nowhere else: not
# the query string, not the body, not a tool argument.
#
# WHERE A SECOND SCHEME PLUGS IN. Everything below `authenticate_api_key!`
# asks only for `current_user`, `current_api_key` and `write_refusal`. An OAuth
# access token (the claude.ai connector flow) would be recognised in that one
# before_action, by its prefix, and would have to supply the same three; see
# docs/AGENT_API.md, "What OAuth would need". None of it is built.
#
# THE WRITE GATES. One action carries every tool, so the default freeze gate
# (every non-GET) would refuse a frozen account's READS. It is lifted for this
# action only, and each writing tool asks `write_refusal` instead (the account
# hold, then the age gate), answering in the tool's own envelope.
class McpController < ActionController::API
  include ApiKeyAuthentication

  # Far above any real message (a tools/call is a few hundred bytes).
  MAX_BODY_BYTES = 64.kilobytes
  UNPARSEABLE = Object.new.freeze

  allow_frozen_account_writes only: :rpc
  skip_before_action :authenticate_api_key!, only: :method_not_allowed
  prepend_before_action :refuse_foreign_origin
  before_action :no_store
  before_action :mark_key_verified, only: :rpc

  # POST /mcp
  def rpc
    payload = parsed_body
    return render_reply(AgentMcp::Server.parse_error) if payload.equal?(UNPARSEABLE)

    return render_batch_over_limit if payload.is_a?(Array) && Rack::Attack.mcp_charge_batch(request, payload.size)

    server = AgentMcp::Server.new(run_tool: method(:run_tool))
    render_reply server.handle(payload, version_header: request.headers["MCP-Protocol-Version"])
  end

  # GET and DELETE /mcp. A GET would open a server-to-client event stream and a
  # DELETE would end a session; this server has neither. "The server MUST
  # either return Content-Type: text/event-stream in response to this HTTP GET,
  # or else return HTTP 405 Method Not Allowed" (basic/transports).
  def method_not_allowed
    response.set_header("Allow", "POST")
    # In JSON-RPC, as this endpoint's other transport refusals are (the Origin
    # 403, the 400s), and on purpose NOT a new code in the agent API's error
    # envelope: that vocabulary is the one the public guide documents, and
    # /api/v1 has no 405 to share it with.
    render json: AgentMcp::Server.error_message(nil, AgentMcp::Protocol::INVALID_REQUEST,
                                                "This MCP endpoint takes POST only. It offers no event stream and no session."),
           status: :method_not_allowed
  end

  private

  # Run one tool for the authenticated player. Returns the operation's Outcome;
  # the two exceptions an operation raises on purpose become the same
  # `not_found` and `bad_request` REST answers with.
  def run_tool(tool, arguments)
    refusal = write_refusal
    return Api::V1::Operations::Outcome.refused(refusal) if tool.writes? && refusal

    tool.call(user: current_user, api_key: current_api_key, arguments: arguments, writable: refusal.nil?)
  rescue ActiveRecord::RecordNotFound, ActionController::BadRequest => e
    Api::V1::Operations::Outcome.refused(api_exception_refusal(e))
  rescue StandardError => e
    log_api_error(e)
    raise if reraise_unexpected_api_errors?

    raise AgentMcp::Server::ToolCrashed
  end

  # The body, parsed here and not through `params`: a JSON-RPC batch is an
  # array, and a body that is not JSON must be answered in JSON-RPC (-32700).
  # The parser's own message is never echoed; it quotes the input.
  def parsed_body
    raw = request.raw_post.to_s
    return UNPARSEABLE if raw.bytesize > MAX_BODY_BYTES

    raw = raw.dup.force_encoding(Encoding::UTF_8)
    return UNPARSEABLE unless raw.valid_encoding?

    JSON.parse(raw)
  rescue JSON::ParserError, EncodingError
    UNPARSEABLE
  end

  def render_reply(reply)
    return head(reply.status) if reply.body.nil?

    render json: reply.body, status: reply.status
  end

  # Rails parses a JSON body before the action runs (parameter wrapping), so a
  # body that is not JSON arrives here as an exception, not in #rpc.
  def render_api_malformed_body(_exception = nil)
    render_reply(AgentMcp::Server.parse_error)
  end

  # "Servers MUST validate the Origin header on all incoming connections to
  # prevent DNS rebinding attacks. If the Origin header is present and invalid,
  # servers MUST respond with HTTP 403 Forbidden" (basic/transports, 2025-11-25).
  #
  # An Origin header means a browser page is the caller. MCP clients are not
  # pages and send none; the only Origin accepted is this site's own. The key
  # is not an ambient credential, so this is a second wall, not the first.
  def refuse_foreign_origin
    origin = request.headers["Origin"]
    return if origin.blank? || origin == request.base_url

    render json: AgentMcp::Server.error_message(nil, AgentMcp::Protocol::INVALID_REQUEST,
                                                "Requests from this Origin are not accepted."),
           status: :forbidden
  end

  # Runs after authenticate_api_key!, so only for a key that is real. Tells the
  # throttle this key is a player's: it is then limited by its own bucket and
  # not by the address it calls from (config/initializers/rack_attack.rb).
  def mark_key_verified
    Rack::Attack.mcp_mark_verified(request)
  end

  # A batch whose messages, charged one each, put the key over its limit. The
  # same answer the throttle itself gives, and nothing in the batch has run.
  def render_batch_over_limit
    response.set_header("Retry-After", "60")
    render json: { error: { code: "rate_limited", message: "Too many requests. Retry after 60 seconds." }, retry_after: 60 },
           status: :too_many_requests
  end

  # Every answer is one player's data, or a spend.
  def no_store
    response.set_header("Cache-Control", "no-store")
  end
end
