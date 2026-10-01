# The tools the /mcp endpoint offers (docs/AGENT_API.md, "MCP"): one per agent
# API endpoint, each running that endpoint's operation.
#
#   tool              REST                                    operation
#   get_me            GET   /api/v1/me                        GetMe
#   list_contests     GET   /api/v1/contests                  ListContests
#   get_contest       GET   /api/v1/contests/:slug            GetContest
#   get_leaderboard   GET   /api/v1/contests/:slug/leaderboard GetLeaderboard
#   list_my_entries   GET   /api/v1/entries                   ListEntries
#   get_entry         GET   /api/v1/entries/:slug             GetEntry
#   submit_entry      POST  /api/v1/contests/:slug/entries    SubmitEntry
#   edit_entry        PATCH /api/v1/entries/:slug             EditEntry
#
# The descriptions are written for a model deciding which tool to call and what
# to tell the player; the schemas describe the arguments, and the operations
# decide whether a value is acceptable.
module AgentMcp
  module Tools
    Ops = Api::V1::Operations

    CONTEST_SLUG = { type: "string", description: "The contest's slug, from list_contests (contests[].slug)." }.freeze
    ENTRY_SLUG = { type: "string", description: "The entry's slug, from list_my_entries (entries[].slug) " \
                                                "or from the result of submit_entry." }.freeze
    LIMIT = { type: "integer", minimum: 1, maximum: Api::V1::Pagination::MAX_LIMIT,
              description: "Page size. Default #{Api::V1::Pagination::DEFAULT_LIMIT}, " \
                           "maximum #{Api::V1::Pagination::MAX_LIMIT}." }.freeze
    OFFSET = { type: "integer", minimum: 0,
               description: "Rows to skip. Default 0. Read pagination.has_more to know if there is another page." }.freeze
    MATCHUP_IDS = {
      type: "array", items: { type: "integer", minimum: 1 }, minItems: 1, maxItems: 100, uniqueItems: true,
      description: "The picks: exactly picks_required different ids (normally six), each a teams[].matchup_id " \
                   "from get_contest for this contest. Order does not matter."
    }.freeze

    ALL = [
      Tool.new(
        name: "get_me", title: "Who am I playing as", operation: Ops::GetMe, writes: false,
        description: <<~TEXT
          Call this first. Returns the player this connection acts for: display name, wallet.kind,
          free_entry_tokens, whether the account is on hold, and the API key's expiry.
          wallet.kind must be "managed" to enter a contest from here; "self_custodied" or "none" means
          the player has to enter on turfmonster.media. free_entry_tokens is how many free entries the
          player can spend; null means it could not be read just now, not zero. Changes nothing.
        TEXT
      ),
      Tool.new(
        name: "list_contests", title: "List contests", operation: Ops::ListContests, writes: false,
        description: <<~TEXT,
          Lists contests, newest first: slug, name, entry fee, prizes, lock time, picks_required,
          accepting_entries, and how many entries the player already has in each. Use status "open" to
          find contests that can be entered. A contest with accepting_entries false, cancelled true or
          coming_soon true cannot be entered. Changes nothing.
        TEXT
        arguments: {
          status: { schema: { type: "string", enum: Ops::ListContests::LISTED_STATUSES,
                              description: "Only open contests, or only settled (finished and paid) ones. " \
                                           "Leave out for both." } },
          limit: { schema: LIMIT },
          offset: { schema: OFFSET }
        }
      ),
      Tool.new(
        name: "get_contest", title: "Read a contest and its board", operation: Ops::GetContest, writes: false,
        description: <<~TEXT,
          Returns one contest and its board of teams. Each team has the matchup_id to pick it with, its
          rank, its turf_score multiplier, its opponent and kickoff, and locked (true once its game has
          started: it can no longer be picked). An entry scores, for each pick, the team's real points
          or goals times turf_score. Call this before building a lineup, and again before submitting if
          time has passed, because teams lock at kickoff. Changes nothing.
        TEXT
        arguments: { contest_slug: { schema: CONTEST_SLUG, required: true, param: :slug } }
      ),
      Tool.new(
        name: "get_leaderboard", title: "Read a contest's leaderboard", operation: Ops::GetLeaderboard, writes: false,
        description: <<~TEXT,
          Returns every confirmed entry in a contest, best first, with rank, score and, once the contest
          has settled, payout. Other players' picks are hidden until the contest locks
          (picks_hidden_until_lock). The player's own entries are marked. Changes nothing.
        TEXT
        arguments: {
          contest_slug: { schema: CONTEST_SLUG, required: true, param: :slug },
          limit: { schema: LIMIT },
          offset: { schema: OFFSET }
        }
      ),
      Tool.new(
        name: "list_my_entries", title: "List my entries", operation: Ops::ListEntries, writes: false,
        description: <<~TEXT,
          Lists the player's own confirmed entries, newest first, each with its picks, score, rank,
          payout and whether it is still editable. Pass contest_slug to see only one contest's. An
          unfinished lineup saved on the website is not an entry and is not listed. Changes nothing.
        TEXT
        arguments: {
          contest_slug: { schema: CONTEST_SLUG.merge(description: "Only entries in this contest. Leave out for all."),
                          param: :contest },
          limit: { schema: LIMIT },
          offset: { schema: OFFSET }
        }
      ),
      Tool.new(
        name: "get_entry", title: "Read one of my entries", operation: Ops::GetEntry, writes: false,
        description: <<~TEXT,
          Returns one of the player's own entries: picks with each team's score so far, total score,
          rank, payout, and editable. Another player's entry is not_found; read rivals with
          get_leaderboard. Changes nothing.
        TEXT
        arguments: { entry_slug: { schema: ENTRY_SLUG, required: true, param: :slug } }
      ),
      Tool.new(
        name: "submit_entry", title: "Submit an entry (spends a token)", operation: Ops::SubmitEntry, writes: true,
        operation_options: { key_label: "an idempotency_key argument" },
        keywords: { idempotency_key: :idempotency_key },
        description: <<~TEXT,
          Enters the player in a contest and pays for it in the same call. THIS SPENDS a free entry
          token (or USDC, only if allow_usdc is true) and cannot be undone, so confirm the exact lineup
          with the player first. Returns the new entry and funding (how it was paid).
          idempotency_key is required: make up one value (a UUID) for this entry and send the SAME
          value on every retry. If the call times out, errors without a result, fails with
          chain_unavailable or idempotency_in_progress, or returns "pending": true, call again with
          the same key and the SAME arguments; you get the one entry and nothing is paid twice. Do
          not change the picks or make a new key until you hold a definite answer: a new key before
          then can pay for a second entry. The player is not entered until a call returns an entry.
          Only after a definite refusal may you change matchup_ids or allow_usdc, with a new key. On
          such a refusal nothing was spent: read error.code (no_entry_token, team_locked, invalid_picks,
          duplicate_lineup, contest_locked, entry_limit_reached, wallet_not_server_signable and others)
          and error.message.
        TEXT
        arguments: {
          contest_slug: { schema: CONTEST_SLUG, required: true, param: :slug },
          matchup_ids: { schema: MATCHUP_IDS, required: true },
          idempotency_key: {
            required: true,
            schema: { type: "string", minLength: 1, maxLength: 255, pattern: "^[!-~]+$",
                      description: "A unique value you make up for this one entry, such as a UUID: 1 to 255 " \
                                   "printable characters, no spaces. Reuse it on every retry of this entry." }
          },
          allow_usdc: {
            schema: { type: "boolean", default: false,
                      description: "Leave false. true lets the entry fee be paid in USDC from the player's " \
                                   "wallet when they have no free entry token. Set it only when the player " \
                                   "has told you to spend money." }
          }
        }
      ),
      Tool.new(
        name: "edit_entry", title: "Replace an entry's picks", operation: Ops::EditEntry, writes: true,
        description: <<~TEXT,
          Replaces ALL the picks of one of the player's entries with the given list, before the contest
          locks. Costs nothing and may be repeated. A team whose game has already kicked off cannot be
          added or dropped (team_locked), and the new lineup may not copy another of the player's
          entries in the same contest (duplicate_lineup). Confirm the new lineup with the player first.
          Returns the updated entry.
        TEXT
        arguments: {
          entry_slug: { schema: ENTRY_SLUG, required: true, param: :slug },
          matchup_ids: { schema: MATCHUP_IDS, required: true }
        }
      )
    ].freeze

    BY_NAME = ALL.index_by(&:name).freeze

    def self.find(name)
      BY_NAME[name]
    end

    def self.definitions(version)
      ALL.map { |tool| tool.definition(version) }
    end
  end
end
