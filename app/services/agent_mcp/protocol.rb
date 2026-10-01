# The Model Context Protocol facts the /mcp endpoint is built to
# (docs/AGENT_API.md, "MCP"). Checked against the published specification,
# https://modelcontextprotocol.io/specification/<revision>, on 2026-10-01.
#
# The namespace is AgentMcp, not Mcp: the `mcp` gem (constant `MCP`) is in the
# lockfile as a development dependency of rubocop, and macOS file systems do not
# tell `Mcp` from `MCP`.
module AgentMcp
  module Protocol
    # The revisions this server speaks, oldest first. What differs between them,
    # as far as this server is concerned:
    #
    #   2025-03-26  JSON-RPC batches are allowed in a POST body. A tool result is
    #               `content` only. No MCP-Protocol-Version header exists.
    #   2025-06-18  Batches are removed. Tool results may carry
    #               `structuredContent`; tools and serverInfo gain `title`. The
    #               client sends MCP-Protocol-Version on every later request.
    #   2025-11-25  Nothing this server uses changes. (It adds tasks, icons and
    #               URL elicitation, none of which is offered here.)
    #
    # NOT SPOKEN: 2026-07-28, the current revision. It drops the `initialize`
    # handshake: every request carries its version and capabilities in
    # `params._meta`, mirrored in Mcp-Method and Mcp-Name headers, and a server
    # answers `server/discover`. A client that speaks both eras tries that
    # first (Claude Code 2.1.286 does: its first POST is `server/discover` at
    # 2026-07-28) and falls back to `initialize` when the answer is a 400 whose
    # body is "not a recognized modern JSON-RPC error" (2026-07-28,
    # basic/transports/streamable-http, "Backward Compatibility"). So the
    # refusal of an unknown version below must stay a plain -32600 and must
    # NEVER use the modern codes -32020 to -32022: answering with one of those
    # would tell the client this is a modern server, and it would stop falling
    # back. test/controllers/mcp_controller_test.rb holds that.
    VERSIONS = %w[2025-03-26 2025-06-18 2025-11-25].freeze
    LATEST = VERSIONS.last

    # "If the server does not receive an MCP-Protocol-Version header […] the
    # server SHOULD assume protocol version 2025-03-26" (2025-06-18 and
    # 2025-11-25, basic/transports, "Protocol Version Header"). This server keeps
    # no session, so the header is the only way it knows what was negotiated.
    HEADER_ABSENT = "2025-03-26".freeze

    BATCHING = %w[2025-03-26].freeze
    STRUCTURED_CONTENT_SINCE = "2025-06-18".freeze
    TITLES_SINCE = "2025-06-18".freeze

    PARSE_ERROR = -32_700
    INVALID_REQUEST = -32_600
    METHOD_NOT_FOUND = -32_601
    INVALID_PARAMS = -32_602
    INTERNAL_ERROR = -32_603

    # Reserved by revision 2026-07-28 for HeaderMismatch, MissingRequiredClient-
    # Capability and UnsupportedProtocolVersion. This server must not emit them.
    MODERN_ERROR_CODES = [-32_020, -32_021, -32_022].freeze

    # One POST may carry this many messages (2025-03-26 only). A batch counts
    # once against the rate limit, so it may not be a way around it.
    MAX_BATCH = 10

    def self.supported?(version)
      VERSIONS.include?(version)
    end

    def self.batching?(version)
      BATCHING.include?(version)
    end

    # Revisions are ISO dates, so string order is revision order.
    def self.structured_content?(version)
      version >= STRUCTURED_CONTENT_SINCE
    end

    def self.titles?(version)
      version >= TITLES_SINCE
    end
  end
end
