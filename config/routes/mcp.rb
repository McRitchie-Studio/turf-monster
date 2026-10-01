# The MCP endpoint (docs/AGENT_API.md, "MCP"), drawn at the top level of
# config/routes.rb: it sits OUTSIDE the /api namespace and its catch-all 404.
#
# It lives here, not inline, for the reason config/routes/api_v1.rb does:
# docs/workflows cites config/routes.rb by line number.
#
# One endpoint. POST carries every JSON-RPC message. Every other verb is a 405:
# a GET would open an event stream and a DELETE end a session, and this server
# has neither. `format: false`, so "/mcp.json" is not a second spelling.
post  "mcp", to: "mcp#rpc", format: false
match "mcp", to: "mcp#method_not_allowed", via: %i[get put patch delete], format: false
