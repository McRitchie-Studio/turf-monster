module Cdp
  # Mints the single-use CDP session token and hands the Coinbase-hosted
  # widget URL back to the client:
  #
  #   POST /cdp/onramp_sessions  → { url: } (buy USDC into the user's wallet)
  #   POST /cdp/offramp_sessions → { url: } (cash out USDC to fiat)
  #
  # See docs/CDP_RAMP_INTEGRATION.md §8. Security posture (Coinbase explicitly
  # holds the developer liable for a misused session-token mint endpoint):
  #   - Cdp::BaseController auth (hard JSON 401 for every unauthenticated
  #     format; no HTML redirect into a final 200 app shell)
  #   - geo gates: the state blocklist (require_geo_allowed) + the Cdp::Catalog
  #     country/subdivision availability check (fails closed)
  #   - per-user rack-attack throttle "cdp_sessions/user" (config/initializers/
  #     rack_attack.rb)
  #   - strict explicit CORS in Cdp::BaseController: production app origin only
  #     by default, localhost:3100 in non-production, no wildcards.
  #
  # Tokens are single-use with a 5-minute TTL — minted at click time, never at
  # page render, never cached (§5).
  class RampSessionsController < BaseController
    # B4 / OPSEC-048: ramp sessions move money — frozen accounts can't open them.
    before_action :require_unfrozen_account
    before_action :require_geo_allowed

    def create_onramp
      create_session(:onramp)
    end

    def create_offramp
      create_session(:offramp)
    end

    private

    def create_session(direction)
      address, mode = wallet_for(direction)
      if address.blank?
        return render json: { error: "Connect a wallet first." }, status: :unprocessable_entity
      end

      unless ramp_available?(direction)
        return render json: { error: unavailable_message(direction) }, status: :unprocessable_entity
      end

      # Row first (status: initiated), so partner_user_ref exists before any
      # CDP call and a mint failure leaves a diagnosable record behind.
      ramp = nil
      rescue_and_log(target: current_user) do
        ramp = CdpRampTransaction.create!(
          user: current_user,
          direction: direction,
          wallet_address: address,
          wallet_mode: mode
        )
      end

      snapshot_baseline_usdc(ramp) if ramp && direction == :onramp

      rescue_and_log(target: ramp, parent: current_user) do
        token = SessionTokenService.new.mint(address: address, client_ip: cdp_client_ip)
        url = build_url(direction, ramp, token)
        ramp.mark_token_minted!
        # Start the CDP status poll loop NOW — server-side reconciliation
        # must never hinge on the return redirect (spec Risks: an
        # un-allowlisted domain or a closed Coinbase tab silently drops it
        # while the transaction still completes; offramp to_address discovery
        # MUST run or the 30-minute cashout window lapses with no send). The
        # return-page hit just (re-)schedules this same idempotent loop.
        poll_job_class(direction).schedule_from_mint(ramp)
        # partner_user_ref rides along (additive to the spec's { url: }) so
        # the cdp-ramp modal can poll /cdp/ramp_status/:ref immediately
        # instead of parsing the ref back out of the widget URL.
        render json: { url: url, partner_user_ref: ramp.partner_user_ref }
      end
    rescue Cdp::Client::RateLimitError
      render json: { error: "Coinbase is busy right now — please try again in a moment." },
             status: :too_many_requests
    rescue Cdp::Client::Error
      render json: { error: "Couldn't start a Coinbase session. Please try again." },
             status: :bad_gateway
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # §5 address selection — BOTH DIRECTIONS ASK THE SESSION. Credit the wallet
    # this session can actually spend from, and source from the one it can sign
    # with; those are the same question, so they get the same answer.
    #
    #   onramp  → DESTINATION wallet: web3 when this session can produce Phantom
    #             signatures (wallet_context.web3?), else the managed web2 wallet.
    #   offramp → the SOURCE wallet that will sign the post-widget send: the same
    #             rule, for the same reason.
    #
    # THE ASYMMETRY THIS REPLACED COST REAL MONEY. The onramp used to take
    # User#solana_address UNCONDITIONALLY, and that method prefers web3
    # (user.rb). A COMBO account — managed wallet plus a linked Phantom — signed
    # in with Google or a magic link is a WEB2 session, and
    # ContestsController#resolve_web2_entry_funding! spends its web2 address:
    # its own comment warns "a managed+phantom combo account signs with — and
    # spends from — the custodial wallet the server holds, never the web3
    # address (which #solana_address would otherwise prefer and desync from the
    # keypair)". So the deposit landed at Phantom while the entry was charged at
    # the managed wallet: the user paid, and stayed blocked. 12 such accounts
    # existed in prod on 2026-09-06.
    #
    # SESSION, NOT ACCOUNT IDENTITY. wallet_context.web3? reads the SESSION
    # (studio-engine SessionContext#mode), so the same combo account correctly
    # gets Phantom when it signed in WITH Phantom and the managed wallet when it
    # signed in with email — which is exactly when each one can pay.
    def wallet_for(direction)
      user = current_user
      if wallet_context.web3? && user.web3_solana_address.present?
        [user.web3_solana_address, :web3]
      elsif direction == :onramp && user.web2_solana_address.blank?
        # A web3-only account on a session that cannot sign with it (an admin
        # impersonating, say). There is no managed wallet to fall back to, so
        # credit the only address the account has rather than refusing — the
        # onramp is a DEPOSIT, and a deposit to the user's own wallet is never
        # unsafe, merely less useful than it could be.
        [user.web3_solana_address, :web3]
      else
        [user.web2_solana_address, :web2]
      end
    end

    # §13 catalog gate — FAILS CLOSED: a Coinbase outage or an undetected US
    # state (subdivision required for country=US) yields unavailable, never a
    # 500. One Catalog per request (per-instance memo over Rails.cache).
    def ramp_available?(direction)
      catalog = Catalog.new
      if direction == :onramp
        catalog.onramp_available?(country: geo_country, subdivision: geo_state)
      else
        catalog.offramp_available?(country: geo_country, subdivision: geo_state)
      end
    end

    # Balance-anchored purchase confirmation, half 1: snapshot the destination
    # wallet's USDC before the buy so the ramp_status poll can recognize
    # arrival by balance delta. Coinbase's transactions API does not attribute
    # guest-checkout buys to partnerUserRef (observed 2026-06-10), so the
    # wallet itself is the signal that always fires. Fail-open: a failed
    # snapshot only disables balance confirmation for this session.
    def snapshot_baseline_usdc(ramp)
      baseline = Solana::Vault.new.fetch_wallet_balances(ramp.wallet_address)[:usdc]
      return if baseline.nil?
      ramp.update!(raw_payload: (ramp.raw_payload || {}).merge("baseline_usdc" => baseline.to_s))
    rescue StandardError => e
      Rails.logger.warn "[cdp] baseline snapshot failed for #{ramp.partner_user_ref}: #{e.message}"
    end

    # Optional widget prefill (e.g. the contest entry fee from the auth
    # modal's picker). Strictly validated; anything off-pattern or out of
    # range drops the param entirely — the buyer just types an amount.
    def preset_fiat_param
      raw = params[:preset_fiat].to_s
      return nil unless raw.match?(/\A\d{1,3}(\.\d{1,2})?\z/)
      amount = BigDecimal(raw)
      amount.between?(2, 500) ? format("%g", amount) : nil
    end

    # Coinbase rejects private/loopback clientIp outright ("private IP
    # addresses are not allowed") — in local dev substitute the machine's
    # real egress IP (what production would see via Heroku's XFF).
    def cdp_client_ip
      ip = request.remote_ip
      addr = IPAddr.new(ip)
      return ip unless Rails.env.development? && (addr.loopback? || addr.private?)
      self.class.dev_public_ip
    end

    def self.dev_public_ip
      @dev_public_ip ||= ENV["DEV_CLIENT_IP"].presence ||
        Net::HTTP.get(URI("https://checkip.amazonaws.com")).strip
    end

    def unavailable_message(direction)
      verb = direction == :onramp ? "Buying USDC" : "Cashing out"
      "#{verb} via Coinbase isn't available in your region yet."
    end

    def poll_job_class(direction)
      direction == :onramp ? OnrampPollJob : OfframpPollJob
    end

    def build_url(direction, ramp, token)
      if direction == :onramp
        OnrampUrl.build(
          session_token: token,
          partner_user_ref: ramp.partner_user_ref,
          redirect_url: cdp_onramp_return_url,
          preset_fiat_amount: preset_fiat_param
        )
      else
        OfframpUrl.build(
          session_token: token,
          partner_user_ref: ramp.partner_user_ref,
          redirect_url: cdp_offramp_return_url
        )
      end
    end
  end
end
