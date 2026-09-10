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
