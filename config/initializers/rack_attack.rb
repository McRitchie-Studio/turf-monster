# OPSEC-019: rate limiting via rack-attack.
#
# Protects:
#   - login + wallet-auth endpoints from credential stuffing / sybil signup
#   - webhook endpoints from signature-verification DoS
#   - faucet / airdrop from devnet abuse (also defense-in-depth on top of
#     the OPSEC-020 production guards)
#   - email verification + Stripe checkout from request flood / fee bleed
#
# Throttles are intentionally generous for legit usage. If you see a
# legit user hitting a throttle in error logs, raise the limit. The point
# is to make scripted brute force expensive, not to harass humans.
#
# Caching: defaults to Rails.cache. In production set REDIS_URL → Rails
# uses Redis-backed cache automatically. Disabled in test env so tests
# don't accidentally hit throttles (an explicit Rack::Attack-aware test
# can re-enable via Rack::Attack.enabled = true around its assertions).
#
# Cache outage: EVERY RULE HERE FAILS OPEN, by decision. Production's
# Rails.cache is a redis_cache_store whose error_handler swallows connection
# errors (config/environments/production.rb), so while Redis is down an
# increment answers nil rather than raising. rack-attack 6.8 reads that nil as
# a new bucket and counts 1 (`result || 1` in Rack::Attack::Cache#do_count;
# RedisCacheStoreProxy defines its own #increment only for ActiveSupport < 6, so
# on this Rails the store's nil reaches do_count unchanged), every limit here is
# at least 1, and so no request is throttled until Redis is back. Nothing
# raises, so no `rescue` in this file runs either. The outage is loud even so:
# the error_handler (CacheErrorReporter) logs "[cache] increment failed" on
# every counted request and reports to Sentry once a minute per process.
#
# Failing closed was weighed rule by rule and refused, because a closed rule
# refuses EVERYONE it matches, not only the abuser:
#   - page views (referral_visit_allowed?): the click is recorded, as it would
#     be with Redis up. Dropping it would lose every real person's click for
#     the length of the outage to cap a script that happens to run inside it.
#   - login, signup, magic link, email verification, wallet sign-in: a closed
#     rule is a sign-in outage for every user. Turf has no passwords (POST
#     /login only bounces to the magic-link page), magic links stay single-use
#     and wallet signatures verified; only the rate is lost.
#   - checkout, deposit, cash-out, withdraw: a closed rule stops every purchase
#     and every cash-out. Each is behind its own authorization, and cash-out is
#     bounded by its state machine (cdp_offramp_send/user below). The faucet and
#     airdrop are production-disabled outright (OPSEC-020).
#   - webhooks: a closed rule drops a provider's deliveries; each is still
#     signature-verified.
#   - the agent API and /mcp: every key is still authenticated per request.
# What the outage costs is the RATE: for its length, brute force and
# table-growth scripts are bounded only by the guards behind each rule.
# test/initializers/rack_attack_cache_outage_test.rb pins this against a store
# that fails the way production's does.

Rails.application.config.middleware.use Rack::Attack

if Rails.env.test?
  Rack::Attack.enabled = false
end

class Rack::Attack
  ### Throttle: login (engine route) — IP + email
  # Browser flow targets — keep moderate (a real user fat-fingering 6 times shouldn't lock out)
  throttle("login/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/login"
  end

  throttle("login/email", limit: 5, period: 1.minute) do |req|
    if req.post? && req.path == "/login"
      req.params["email"].to_s.downcase.presence
    end
  end

  ### Throttle: Solana wallet auth — nonce + verify
  throttle("solana_nonce/ip", limit: 30, period: 1.minute) do |req|
    req.ip if req.get? && req.path == "/auth/solana/nonce"
  end

  throttle("solana_verify/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/auth/solana/verify"
  end

  ### Throttle: client-side wallet-failure reports
  # An UNAUTHENTICATED endpoint that writes an error_logs row per call, so it is
  # a table-growth vector as well as a request one. 20/min is far above what a
  # human retrying Connect can produce (each attempt costs a wallet prompt) and
  # far below what a script needs to be worth running. Dropping a report past the
  # limit is the correct trade: the row is diagnostic, never load-bearing.
  throttle("solana_report_failure/ip", limit: 20, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/auth/solana/report_failure"
  end

  ### Throttle: account-linking wallet sig (logged-in)
  throttle("link_solana/ip", limit: 5, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/account/link_solana"
  end

  ### Throttle: webhook endpoints — DoS protection on signature verification
  # Stripe normally delivers a handful per second at peak. 100/min leaves
  # ample headroom while killing flood attacks.
  throttle("webhooks/stripe", limit: 100, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/webhooks/stripe"
  end

  throttle("webhooks/paypal", limit: 100, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/webhooks/paypal"
  end

  throttle("webhooks/coinflow", limit: 100, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/webhooks/coinflow"
  end

  throttle("webhooks/aeropay", limit: 100, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/webhooks/aeropay"
  end

  ### Throttle: devnet faucet / airdrop — money-cost endpoints
  # Faucet is already prod-disabled per OPSEC-020 but rate-limited on devnet
  # too because admin SOL gets burned via mint_spl + ATA creation.
  # Dev: a fast per-60s cap so hammering "Mint USDC" trips the global wait modal
  # and resets quickly (the rate-limit playground). Prod: the 5/hour money cap
  # (admin SOL is burned per mint). Both emit the tier-1 "general" 429 → the
  # _rate_limit_general wait modal (see throttled_responder + authedFetch).
  faucet_limit, faucet_period = Rails.env.development? ? [3, 60.seconds] : [5, 1.hour]
  throttle("faucet/ip", limit: faucet_limit, period: faucet_period) do |req|
    req.ip if req.post? && req.path == "/faucet"
  end

  throttle("airdrop/ip", limit: 5, period: 1.hour) do |req|
    req.ip if req.post? && req.path == "/wallet/airdrop"
  end

  ### Throttle: Stripe checkout creation — fee bleed protection
  throttle("stripe_checkout/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.post? && (req.path == "/tokens/stripe_checkout" || req.path == "/wallet/stripe_deposit")
  end

  ### Throttle: CDP ramp session-token mint — money surface, per-user cap
  # POST /onramp/v1/token has NO documented rate limit and Coinbase explicitly
  # holds the developer liable for misuse of an unsecured mint endpoint — so we
  # keep our own throttle on top of the controller's auth gate. Keyed by the
  # session's user id (the endpoints require auth; per-user beats per-IP for
  # shared NATs), falling back to IP for unauthenticated probes. Tokens are
  # single-use with a 5-minute TTL, so 10/min is generous for a human retrying
  # and expensive for a script. Emits the tier-1 "general" 429 → wait modal.
  throttle("cdp_sessions/user", limit: 10, period: 1.minute) do |req|
    if req.post? && (req.path == "/cdp/onramp_sessions" || req.path == "/cdp/offramp_sessions")
      session = req.env["rack.session"] || {}
      user_id = session[Studio.session_key.to_s] || session[Studio.session_key]
      (user_id || req.ip).to_s
    end
  end

  ### Throttle: Phantom cash-out cosign — ADMIN SOL bleed protection
  # POST /cdp/offramp/cosign_send spends the house's SOL: since
  # phantom-cashout-needs-sol the ADMIN is the fee payer on the cash-out wire,
  # so every wire this endpoint hands back is a broadcastable claim on
  # SOLANA_ADMIN_KEY — the same wallet that pays for entries, mints and
  # payouts. A new POST route defaults to EXEMPT here (see the allowlist note
  # below), which is exactly how a money surface ships uncapped.
  #
  # The state machine is the real bound — Cdp::OfframpSendsController#cosign
  # claims the row (:cdp_created -> :sending) under a row lock and renders
  # nothing when the claim fails, so one row yields one wire. This throttle is
  # the second wall: it caps the RATE at which a script can drive the verified-
  # dead rewind path across many rows, and it costs a human nothing (a cash-out
  # is one cosign, retried by hand at most a few times inside a 30-minute
  # window). Keyed per-user like the session mint above, IP as the fallback.
  # Prepare is capped alongside it — it is free to serve but it is the step
  # that precedes every cosign.
  throttle("cdp_offramp_send/user", limit: 10, period: 1.minute) do |req|
    if req.post? && (req.path == "/cdp/offramp/cosign_send" || req.path == "/cdp/offramp/prepare_send")
      session = req.env["rack.session"] || {}
      user_id = session[Studio.session_key.to_s] || session[Studio.session_key]
      (user_id || req.ip).to_s
    end
  end

  ### Throttle: PayPal order/capture creation — fee bleed parity with stripe_checkout
  throttle("paypal_checkout/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.post? && (req.path == "/tokens/paypal_order" || req.path == "/tokens/paypal_capture")
  end

  ### Throttle: Coinflow checkout-link creation — fee bleed parity with paypal/stripe
  throttle("coinflow_checkout/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/tokens/coinflow_order"
  end

  ### Throttle: Aeropay deposit creation — fee bleed parity with coinflow/paypal/stripe
  throttle("aeropay_checkout/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/tokens/aeropay_order"
  end

  ### Throttle: email verification — outbound spam prevention
  throttle("email_verification/ip", limit: 3, period: 1.hour) do |req|
    req.ip if req.post? && req.path == "/email_verification"
  end

  ### Throttle: magic-link request — outbound email spam + can't-spam-a-mailbox
  # Per-email is the important cap (limits mail to a single address); IP is a
  # generous backstop for shared NATs. The GET confirmation page is inert, and
  # the POST consume relies on CSRF + single-use token semantics; brute-forcing
  # an HMAC token is infeasible and legit clicks must always go through.
  # Dev gets looser caps so a single localhost (one IP, many test addresses)
  # doesn't trip the limit during normal testing; prod stays strict.
  magic_link_ip_limit    = Rails.env.development? ? 10 : 5
  magic_link_email_limit = Rails.env.development? ? 5 : 3
  throttle("magic_link/ip", limit: magic_link_ip_limit, period: 1.hour) do |req|
    req.ip if req.post? && req.path == "/magic_link"
  end
  throttle("magic_link/email", limit: magic_link_email_limit, period: 1.hour) do |req|
    req.params["email"].to_s.downcase.presence if req.post? && req.path == "/magic_link"
  end

  ### Throttle: slate-drop "notify me" — anonymous table-growth vector
  # POST /drop-signups (the /turf-monster-v2 explainer) needs no account, so
  # every call can write a row. A person submits once, maybe twice after a typo;
  # a household or office behind one NAT a handful of times. Per-IP is the flood
  # cap; per-email stops one address being hammered from many IPs (a resubmit
  # writes nothing, but it still costs a lookup). Exact path: the route is
  # `format: false`, so there is no .json twin to slip past it. Dev is looser so
  # one localhost can try many addresses, as magic_link above.
  drop_signup_ip_limit = Rails.env.development? ? 60 : 10
  throttle("drop_signups/ip", limit: drop_signup_ip_limit, period: 1.hour) do |req|
    req.ip if req.post? && req.path == "/drop-signups"
  end
  throttle("drop_signups/email", limit: 5, period: 1.hour) do |req|
    req.params["email"].to_s.strip.downcase.presence if req.post? && req.path == "/drop-signups"
  end

  ### Throttle: contest chat — message-post flood backstop
  # Coarse per-IP cap; MessagesController enforces a precise per-user cooldown.
  throttle("chat_messages/ip", limit: 40, period: 1.minute) do |req|
    req.ip if req.post? && req.path.match?(%r{\A/contests/[^/]+/messages\z})
  end

  ### Throttle: signup — sybil + spam prevention (prelaunch audit H5)
  # Engine route POST /signup is the browser-flow registration. The magic-link
  # request (POST /magic_link) is the primary email-signup surface now and is
  # throttled by the magic_link rules above.
  throttle("signup/ip", limit: 5, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/signup"
  end

  ### Throttle: wallet withdraw — money-out, strict cap (prelaunch audit H5)
  throttle("wallet_withdraw/ip", limit: 5, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/wallet/withdraw"
  end

  ### Throttle: on-chain entry preparation — sign-build flood backstop (prelaunch audit H5)
  # /contests/:id/prepare_entry builds a partially-signed entry TX. Cheap on
  # paper but it hits Solana RPC + holds DB locks; flood mitigation worth it.
  throttle("prepare_entry/ip", limit: 30, period: 1.minute) do |req|
    req.ip if req.post? && req.path.match?(%r{\A/contests/[^/]+/prepare_entry\z})
  end

  ### Throttle: hold-window funding pre-check — getProgramAccounts amplification (2026-06-13)
  # /contests/:id/check_funding fires automatically on every hold-START, and each
  # call FORCE-busts the entry-tokens cache then does a fresh getProgramAccounts
  # (expensive + Helius-rate-limited) PLUS a
  # getTokenAccountsByOwner — two RPCs per invocation. It is NOT on the general/ip
  # allowlist (a new POST route defaults to EXEMPT), so without this a buggy or
  # malicious authed client (rapid hold start/release) could drive unbounded
  # getProgramAccounts load against Helius. 30/min mirrors prepare_entry — ample
  # for a human re-holding, expensive for a script. Tier-1 "general" 429 → wait
  # modal (beginFundingCheck goes through authedFetch).
  throttle("check_funding/ip", limit: 30, period: 1.minute) do |req|
    req.ip if req.post? && req.path.match?(%r{\A/contests/[^/]+/check_funding\z})
  end

  ### Throttle: username update — squatting / spam prevention (prelaunch audit H5)
  # On-chain set_username costs admin SOL when server-signs; throttling caps
  # spend. Phantom-cosigned path costs the user instead but still rate-limited
  # for spam control.
  throttle("update_username/ip", limit: 10, period: 1.minute) do |req|
    req.ip if req.post? && req.path == "/account/update_username"
  end

  ### Throttle: TIER-1 general interactive writes (rate-limit epic, Phase 1)
  # A forgiving per-IP flood backstop on the bursty guest/player write actions.
  # STRICT allowlist: the matcher returns ip ONLY for these enumerated write
  # paths, so a new POST route defaults to EXEMPT and the dedicated throttles
  # above are never loosened/duplicated. 90/60s clears a confirm-entry's replay
  # fan-out (≤6 toggle_selection + enter) without ever tripping a human; on
  # exceed → the tier-1 "general" 429 → the global wait modal (for paths that
  # go through authedFetch; the bare-fetch write paths are server-protected
  # here and get the modal once migrated — Phase 1b).
  throttle("general/ip", limit: 90, period: 60.seconds) do |req|
    next unless req.post? || req.patch? || req.put? || req.delete?
    req.ip if req.path.match?(%r{\A/contests/[^/]+/(toggle_selection|enter|clear_picks)\z})
  end

  ### Throttle: the agent API (/api/) — its own tier (docs/AGENT_API.md)
  # Every other rule in this file is an allowlist of browser paths, so a new
  # route defaults to EXEMPT. These two are deliberately a PREFIX match
  # instead: every endpoint added under /api/ is throttled the day it ships,
  # with nobody having to remember this file.
  #
  # api/key — the real limit. Keyed on the bearer key, because that is the
  # client: one agent, one player, whatever server it happens to call from.
  # 120/min is far above an agent reading a board and filing an entry, and far
  # below a loop that has lost the plot. The discriminator is a DIGEST of the
  # key, so the raw key never becomes a cache key, and it needs no database
  # read — a revoked or made-up key is still counted, against itself.
  #
  # api/ip — the flood backstop, and why it is so much looser. Agents call
  # from shared cloud egress (many players behind one provider's addresses),
  # so a tight per-IP cap would throttle strangers for each other's traffic.
  # But api/key alone can be sidestepped by sending a different made-up key on
  # every request, each landing in its own empty bucket and each costing an
  # indexed lookup. 600/min per address caps that without touching real use.
  API_PATH_PREFIX = "/api/".freeze
  API_BEARER_PATTERN = /\ABearer\s+(\S+)\s*\z/i

  def self.api_request?(req)
    req.path.start_with?(API_PATH_PREFIX)
  end

  def self.api_key_discriminator(req)
    token = req.env["HTTP_AUTHORIZATION"].to_s[API_BEARER_PATTERN, 1]
    token.present? ? Digest::SHA256.hexdigest(token)[0, 32] : nil
  end

  throttle("api/key", limit: 120, period: 1.minute) do |req|
    api_key_discriminator(req) if api_request?(req)
  end

  throttle("api/ip", limit: 600, period: 1.minute) do |req|
    req.ip if api_request?(req)
  end

  ### Throttle: the MCP endpoint (/mcp) — the agent API for chat clients
  # The same player traffic as /api/, through one path, so the same per-key
  # limit. What differs is the per-IP side, because of WHO calls.
  #
  # A claude.ai connector does not call from the player's address. It calls
  # from Anthropic's, and every player using a connector shares that range:
  # "Anthropic's outbound traffic to your server originates from
  # 160.79.104.0/21" (https://claude.com/docs/connectors/building/authentication,
  # "Network reference", and https://platform.claude.com/docs/en/api/ip-addresses,
  # "Outbound IP addresses"; both read 2026-10-01. The second page lists no
  # outbound IPv6 range: 2607:6bc0::/48 is INBOUND, Anthropic's own API).
  # A per-IP cap on players there is one cap shared by strangers, so one busy
  # player could lock the rest out. So NO per-IP limit is put on a player at
  # all, here or anywhere. The per-IP limit is on requests that have not shown
  # they are a player.
  #
  # mcp/key            120/min on a digest of the bearer key. THE limit for a
  #                    player. Its own bucket: /api/ traffic does not spend it.
  #                    A JSON-RPC batch is charged one per message
  #                    (mcp_charge_batch, called by McpController).
  # mcp/unverified_ip  per address, for a request with no bearer key OR with a
  #                    key this app has not yet seen authenticate. 30/min; 300
  #                    inside Anthropic's range, where one address carries many
  #                    people making their first request.
  #
  # "SEEN AUTHENTICATE" WITHOUT A DATABASE READ HERE. A bearer-shaped string
  # proves nothing: a script can send a different made-up key on every request,
  # each one a fresh mcp/key bucket and each costing a key lookup. So
  # McpController, once a key has authenticated, writes a mark for its digest
  # into this same cache (mcp_mark_verified, kept MCP_VERIFIED_TTL). The throttle
  # reads the mark: one cache read, no database. A marked key is a player and
  # is limited by mcp/key alone. An unmarked one counts against the address
  # until its first request succeeds, which costs a real player one request of
  # the 30. A marked key that then FAILS authentication (revoked, expired,
  # deleted) has its mark removed by that 401 (mcp_clear_verified), so from its
  # next request it is an unknown key again and counts against its address.
  #
  # WHAT THIS DOES NOT STOP. Anthropic's range is not only claude.ai: anyone
  # with an Anthropic API key can point the API's MCP connector at this
  # endpoint with any token they like, so made-up keys CAN arrive from that
  # range without a claude.ai account. They are held to 300/min per address.
  # While such a flood lasts, a player whose key is not yet marked and whose
  # request leaves through the same address gets a 429 on first contact;
  # players already marked are untouched. And the address is the one the
  # Heroku router wrote, never one the caller named
  # (config/initializers/forwarded_headers.rb).
  MCP_PATH = "/mcp".freeze
  MCP_SHARED_EGRESS = [IPAddr.new("160.79.104.0/21")].freeze
  MCP_KEY_LIMIT = 120
  MCP_UNVERIFIED_LIMIT = 30
  MCP_UNVERIFIED_SHARED_EGRESS_LIMIT = 300
  MCP_VERIFIED_TTL = 24.hours

  # Every spelling the router sends to McpController: Rails squeezes repeated
  # slashes and ignores a trailing one.
  def self.mcp_request?(req)
    path = req.path.squeeze("/")
    path = path.chomp("/") if path.length > 1
    path == MCP_PATH
  end

  def self.mcp_shared_egress?(req)
    address = IPAddr.new(req.ip.to_s)
    MCP_SHARED_EGRESS.any? { |range| range.include?(address) }
  rescue IPAddr::Error
    false
  end

  def self.mcp_verified_cache_key(digest)
    "mcp/verified:#{digest}"
  end

  # Has this bearer key authenticated here within MCP_VERIFIED_TTL? Memoised on
  # the request: both throttles ask.
  #
  # A mark that cannot be read counts as no mark, so the key goes to the
  # stricter per-address tier. In production that comes from the read itself:
  # under a Redis outage it answers nil rather than raising. The `rescue` is
  # for a store that raises, which production's does not. Either way it limits
  # nothing during an outage, because the per-address count fails open too
  # (see "Cache outage" at the top of this file).
  def self.mcp_verified?(req)
    return req.env["mcp.key_verified"] if req.env.key?("mcp.key_verified")

    digest = api_key_discriminator(req)
    req.env["mcp.key_verified"] = digest.present? && cache.read(mcp_verified_cache_key(digest)).present?
  rescue StandardError
    req.env["mcp.key_verified"] = false
  end

  # Called by McpController after a key has authenticated. A cache write only
  # when the mark is not already there.
  def self.mcp_mark_verified(req)
    return unless enabled
    return if req.env["mcp.key_verified"]

    digest = api_key_discriminator(req)
    cache.write(mcp_verified_cache_key(digest), 1, MCP_VERIFIED_TTL) if digest
  rescue StandardError => e
    Rails.logger.warn("[rack-attack] mcp verified mark failed: #{e.class}")
  end

  # Called by McpController when a bearer key fails authentication. A cache
  # delete only when this request read a mark, so a made-up key costs nothing.
  def self.mcp_clear_verified(req)
    return unless enabled
    return unless req.env["mcp.key_verified"]

    digest = api_key_discriminator(req)
    cache.delete(mcp_verified_cache_key(digest)) if digest
    req.env["mcp.key_verified"] = false
  rescue StandardError => e
    Rails.logger.warn("[rack-attack] mcp verified clear failed: #{e.class}")
  end

  # A batch reached the app as ONE request and was counted once. Charge the
  # other messages to the key's bucket, and say whether that put it over.
  def self.mcp_charge_batch(req, messages)
    return false unless enabled

    digest = api_key_discriminator(req)
    return false if digest.nil? || messages < 2

    count = nil
    (messages - 1).times { count = cache.count("mcp/key:#{digest}", 1.minute.to_i) }
    count.to_i > MCP_KEY_LIMIT
  rescue StandardError => e
    Rails.logger.warn("[rack-attack] mcp batch charge failed: #{e.class}")
    false
  end

  throttle("mcp/key", limit: MCP_KEY_LIMIT, period: 1.minute) do |req|
    api_key_discriminator(req) if mcp_request?(req)
  end

  unverified_limit = ->(req) { mcp_shared_egress?(req) ? MCP_UNVERIFIED_SHARED_EGRESS_LIMIT : MCP_UNVERIFIED_LIMIT }
  throttle("mcp/unverified_ip", limit: unverified_limit, period: 1.minute) do |req|
    req.ip if mcp_request?(req) && !mcp_verified?(req)
  end

  ### Throttle: agent API key mint — row-growth backstop
  # Authenticated and capped at ApiKey::MAX_ACTIVE_PER_USER live keys, but a
  # mint-revoke loop would still grow api_keys without bound. A person makes a
  # key a handful of times a year.
  #
  # The pattern is every spelling the router sends to api_keys#create: the
  # route takes an optional format and Rails ignores a trailing slash, so
  # `/account/api_keys.html` mints a key exactly as the bare path does. It does
  # not reach `/account/api_keys/:id` (the revoke).
  #
  # Its 429 is this file's JSON, not the keys card, so the card's form reads
  # the status and says so itself (accounts/_api_keys_section).
  API_KEY_MINT_PATH = %r{\A/account/api_keys(?:\.[^/]*)?/?\z}

  throttle("api_key_mint/ip", limit: 10, period: 1.hour) do |req|
    req.ip if req.post? && req.path.match?(API_KEY_MINT_PATH)
  end

  ### Throttle: referral click recording — table-growth backstop
  # Any page GET carrying ?reference=<name> (and the /lp/ and vanity paths) can
  # write a referral_visits row (ReferralVisitTracking). The cookie gate there
  # stops a cookieless script, but a client can make up a new visitor cookie on
  # every request, and each one is a new row. So every write is counted per
  # client address, and past REFERRAL_VISIT_LIMIT in REFERRAL_VISIT_PERIOD the
  # click is not recorded.
  #
  # NOT A 429. The page is always served; only the count is dropped. A viral
  # link sends many people through one carrier NAT address, and they must still
  # get the page. A person follows a few links a minute; the limit is far above
  # that and far below a loop. Keyed on req.ip, the address the Heroku router
  # wrote (config/initializers/forwarded_headers.rb). Asked by the controller
  # rather than matched here because only the controller knows a request is
  # about to write.
  #
  # A cache that cannot be counted RECORDS the click, like every rule in this
  # file (see "Cache outage" at the top). Under a Redis outage production's
  # store answers count 1, so every click is recorded until Redis is back; a
  # store that raises instead takes the `rescue` below to the same answer. The
  # page is served either way.
  REFERRAL_VISIT_LIMIT = 20
  REFERRAL_VISIT_PERIOD = 1.minute

  def self.referral_visit_allowed?(req)
    return true unless enabled

    cache.count("referral_visits/ip:#{req.ip}", REFERRAL_VISIT_PERIOD.to_i) <= REFERRAL_VISIT_LIMIT
  rescue StandardError => e
    Rails.logger.warn("[rack-attack] referral visit count failed: #{e.class}")
    true
  end

  ### Response: throttled requests get 429
  # Tier tag drives the client: tier-1 "general" 429s open the global wait
  # modal (via authedFetch); "auth"-surface 429s keep their own inline UX.
  # Phase 1 uses an explicit auth-name set; Phase 2 (the auth ladder) should
  # switch to prefix-matching (magic_link/*, login/* → auth) so new throttle
  # names are classified without editing this list.
  AUTH_THROTTLE_NAMES = %w[
    login/ip login/email signup/ip
    magic_link/ip magic_link/email email_verification/ip
    solana_nonce/ip solana_verify/ip link_solana/ip
  ].freeze

  self.throttled_responder = lambda do |request|
    match_data = request.env["rack.attack.match_data"] || {}
    retry_after = match_data[:period].to_i
    matched     = request.env["rack.attack.matched"].to_s
    tier        = AUTH_THROTTLE_NAMES.include?(matched) ? "auth" : "general"

    # The agent API answers in ITS envelope ({ error: { code, message } }), the
    # one shape every /api/ response uses, so a client needs a single error
    # parser. No X-RateLimit-Tier: that header drives the browser's wait modal.
    # /mcp answers the same way: a 429 is HTTP, below JSON-RPC, as its 401 is.
    if api_request?(request) || mcp_request?(request)
      next [
        429,
        { "Content-Type" => "application/json", "Retry-After" => retry_after.to_s },
        [{ error: { code: "rate_limited", message: "Too many requests. Retry after #{retry_after} seconds." },
           retry_after: retry_after }.to_json]
      ]
    end

    [
      429,
      {
        "Content-Type" => "application/json",
        "X-RateLimit-Tier" => tier,
        "Retry-After" => retry_after.to_s
      },
      [{ error: "Too many requests. Try again later.", tier: tier, retry_after: retry_after }.to_json]
    ]
  end
end

# Log throttle hits — useful for tuning limits without harming legit users.
ActiveSupport::Notifications.subscribe("throttle.rack_attack") do |_name, _start, _finish, _id, payload|
  req = payload[:request]
  Rails.logger.warn("[rack-attack] throttled match=#{req.env['rack.attack.matched']} ip=#{req.ip} path=#{req.path}")
end
