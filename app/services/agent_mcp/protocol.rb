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
