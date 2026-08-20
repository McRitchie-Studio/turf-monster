require "test_helper"

class Cdp::RampSessionsControllerTest < ActionDispatch::IntegrationTest
  include ActiveJob::TestHelper

  # Available-everywhere catalog stand-in (the controller builds one per
  # request via Cdp::Catalog.new).
  class FakeCatalog
    attr_reader :checks

    def initialize(onramp: true, offramp: true)
      @onramp = onramp
      @offramp = offramp
      @checks = []
    end

    def onramp_available?(country:, subdivision: nil)
      @checks << [:onramp, country, subdivision]
      @onramp
    end

    def offramp_available?(country:, subdivision: nil)
      @checks << [:offramp, country, subdivision]
      @offramp
    end
  end

  # Records the mint call; returns a canned token or raises.
  class FakeTokenService
    attr_reader :mints

    def initialize(token: "tok-test-123", raise_error: nil)
      @token = token
      @raise_error = raise_error
      @mints = []
    end

    def mint(address:, client_ip:, **)
      @mints << { address: address, client_ip: client_ip }
      raise @raise_error if @raise_error
      @token
    end
  end

  setup do
    @user = users(:jordan)
  end

  # AppFlags reads ENV directly — save/restore around each case.
  def with_cdp_ramp(value = "true")
    original = ENV["ENABLE_CDP_RAMP"]
    value.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = value
    yield
  ensure
    original.nil? ? ENV.delete("ENABLE_CDP_RAMP") : ENV["ENABLE_CDP_RAMP"] = original
  end

  def with_env(overrides)
    saved = overrides.keys.index_with { |key| ENV[key] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def with_forgery_protection
    original = ActionController::Base.allow_forgery_protection
    ActionController::Base.allow_forgery_protection = true
    yield
  ensure
    ActionController::Base.allow_forgery_protection = original
  end

  def give_managed_wallet(user = @user)
    user.update!(web2_solana_address: "ManagedWallet#{SecureRandom.hex(4)}",
                 encrypted_web2_solana_private_key: "x")
  end

  # Balance read for the onramp baseline snapshot — stubbed for every session
  # POST so no test reaches a real RPC.
  class FakeBalanceVault
    def initialize(usdc: 10.0)
      @usdc = usdc
    end

    def fetch_wallet_balances(_address)
      { usdc: @usdc }
    end
  end

  def post_session(direction, catalog: FakeCatalog.new, service: FakeTokenService.new,
                   vault: FakeBalanceVault.new, params: {}, headers: {})
    path = direction == :onramp ? cdp_onramp_sessions_path : cdp_offramp_sessions_path
    Cdp::Catalog.stub :new, catalog do
      Cdp::SessionTokenService.stub :new, service do
        Solana::Vault.stub :new, vault do
          post path, params: params, headers: headers, as: :json
        end
      end
    end
  end

  test "404s when the flag is off — even unauthenticated (kill-switch advertises nothing)" do
    with_cdp_ramp(nil) do
      post cdp_onramp_sessions_path, as: :json
      assert_response :not_found

      log_in_as @user
      post cdp_offramp_sessions_path, as: :json
      assert_response :not_found
    end
  end

  test "requires authentication (clean JSON 401 for authedFetch)" do
    with_cdp_ramp do
      post cdp_onramp_sessions_path, as: :json
      assert_response :unauthorized
      assert_equal "unauthenticated", JSON.parse(response.body)["error"]
    end
  end

  test "requires authentication without redirecting raw html clients into the app shell" do
    with_cdp_ramp do
      with_forgery_protection do
        post cdp_onramp_sessions_path, headers: { "Accept" => "text/html" }
      end

      assert_response :unauthorized
      assert_equal "application/json", response.media_type
      assert_equal "unauthenticated", JSON.parse(response.body)["error"]
      assert_nil response.headers["Location"]
    end
  end

  test "sets explicit CORS headers for allowlisted CDP origins" do
    with_cdp_ramp do
      log_in_as @user
      give_managed_wallet

      post_session(:onramp, headers: { "Origin" => "https://turfmonster.media" })

      assert_response :success
      assert_equal "https://turfmonster.media", response.headers["Access-Control-Allow-Origin"]
      assert_equal "true", response.headers["Access-Control-Allow-Credentials"]
      assert_includes response.headers["Vary"], "Origin"
    end
  end

  test "sets explicit CORS headers for APP_HOST and APP_HOST_ALIASES origins" do
    with_env("APP_HOST" => "turfmonster.media", "APP_HOST_ALIASES" => "app.turfmonster.media") do
      with_cdp_ramp do
        log_in_as @user
        give_managed_wallet

        post_session(:onramp, headers: { "Origin" => "https://turfmonster.media" })
        assert_response :success
        assert_equal "https://turfmonster.media", response.headers["Access-Control-Allow-Origin"]

        post_session(:onramp, headers: { "Origin" => "https://app.turfmonster.media" })
        assert_response :success
        assert_equal "https://app.turfmonster.media", response.headers["Access-Control-Allow-Origin"]
      end
    end
  end

  test "blocks unallowlisted CDP origins before minting a session token" do
    with_cdp_ramp do
      log_in_as @user
      give_managed_wallet
      service = FakeTokenService.new

      Cdp::SessionTokenService.stub :new, service do
        post cdp_onramp_sessions_path,
          headers: { "Origin" => "https://evil.example" },
          as: :json
      end

      assert_response :forbidden
      assert_nil response.headers["Access-Control-Allow-Origin"]
      assert_empty service.mints
    end
  end

  test "answers allowlisted CDP preflight without authentication" do
    with_cdp_ramp do
      options cdp_onramp_sessions_path,
        headers: {
          "Origin" => "https://turfmonster.media",
          "Access-Control-Request-Method" => "POST"
        }

      assert_response :no_content
      assert_equal "https://turfmonster.media", response.headers["Access-Control-Allow-Origin"]
      assert_includes response.headers["Access-Control-Allow-Methods"], "POST"
    end
  end

  test "geo-blocked state gets a 403 before any CDP call" do
    with_cdp_ramp do
      give_managed_wallet
      log_in_as @user
      service = FakeTokenService.new
      Studio::GeoSetting.stub :blocked?, true do
        post_session(:onramp, service: service)
      end
      assert_response :forbidden
      assert_empty service.mints
    end
  end

  test "frozen account gets a 403 (OPSEC-048 — ramp sessions move money)" do
    with_cdp_ramp do
      give_managed_wallet
      @user.freeze_for_payment_risk!(reason: "test")
      log_in_as @user
      post_session(:onramp)
      assert_response :forbidden
    end
  end

  test "region unavailable in the CDP catalog → 422, no token minted (fail closed)" do
    with_cdp_ramp do
      give_managed_wallet
      log_in_as @user
      service = FakeTokenService.new
      post_session(:onramp, catalog: FakeCatalog.new(onramp: false), service: service)
      assert_response :unprocessable_entity
      assert_match(/isn't available in your region/, JSON.parse(response.body)["error"])
      assert_empty service.mints
      assert_equal 0, CdpRampTransaction.count
    end
  end

  test "no connected wallet → 422" do
    with_cdp_ramp do
      log_in_as @user
      post_session(:onramp)
      assert_response :unprocessable_entity
      assert_match(/Connect a wallet/, JSON.parse(response.body)["error"])
    end
  end

  test "onramp mints a token and returns the hosted buy URL (row initiated → token_minted)" do
    with_cdp_ramp do
      give_managed_wallet
      log_in_as @user
      catalog = FakeCatalog.new
      service = FakeTokenService.new(token: "tok-abc")

      assert_difference "CdpRampTransaction.count", 1 do
        post_session(:onramp, catalog: catalog, service: service)
      end
      assert_response :success

      ramp = CdpRampTransaction.last
      assert_equal @user.id, ramp.user_id
      assert ramp.onramp?
      assert ramp.token_minted?
      assert ramp.wallet_web2?
      assert_equal @user.web2_solana_address, ramp.wallet_address
      assert_equal "tm-#{@user.id}-#{ramp.id}", ramp.partner_user_ref

      # The mint got the destination address + the request IP (clientIp).
      mint = service.mints.first
      assert_equal @user.web2_solana_address, mint[:address]
      assert mint[:client_ip].present?

      # Catalog was consulted with country + subdivision (undetected → US/nil;
      # the real catalog fails closed on that — the fake just records it).
      assert_equal [:onramp, "US", nil], catalog.checks.first

      body = JSON.parse(response.body)
      url = body["url"]
      assert url.start_with?("https://pay.coinbase.com/buy/select-asset?")
      assert_includes url, "sessionToken=tok-abc"
      assert_includes url, "partnerUserRef=#{ramp.partner_user_ref}"
      assert_includes url, CGI.escape(cdp_onramp_return_url)
      # The ref rides along so the cdp-ramp modal can poll /cdp/ramp_status
      # immediately (additive to the spec's { url: }).
      assert_equal ramp.partner_user_ref, body["partner_user_ref"]

      # Same-origin authedFetch carries no Origin header, so no CORS header is
      # emitted unless the browser is doing an explicit cross-origin request.
      assert_nil response.headers["Access-Control-Allow-Origin"]
    end
  end

  test "session mint schedules the poll loop — reconciliation must never hinge on the return redirect" do
    # The spec's Risks section: an un-allowlisted domain (or a closed
    # Coinbase tab) silently drops the redirect while the transaction still
    # completes. Without a mint-time schedule, onramp rows strand at
    # token_minted and offramp to_address discovery never runs — the
    # 30-minute cashout window lapses with no send.
    with_cdp_ramp do
      give_managed_wallet
      log_in_as @user

      post_session(:onramp)
      assert_response :success
      onramp = CdpRampTransaction.last
      job = enqueued_jobs.find { |j| j[:job] == Cdp::OnrampPollJob }
      assert job, "expected Cdp::OnrampPollJob scheduled at mint time"
      assert_equal onramp.id, job[:args].first["ramp_id"]
      assert job[:at].present?, "first poll must wait (~60s), never run immediately (§11)"
      assert_in_delta Cdp::RampPollJob::MINT_POLL_DELAY.from_now.to_f, job[:at], 5

      post_session(:offramp)
      assert_response :success
      offramp = CdpRampTransaction.last
      job = enqueued_jobs.find { |j| j[:job] == Cdp::OfframpPollJob }
      assert job, "expected Cdp::OfframpPollJob scheduled at mint time"
      assert_equal offramp.id, job[:args].first["ramp_id"]
    end
  end

  test "a failed token mint schedules no poll loop" do
    with_cdp_ramp do
      give_managed_wallet
      log_in_as @user
      service = FakeTokenService.new(raise_error: Cdp::Client::ApiError.new("CDP 500: boom"))
      post_session(:onramp, service: service)
      assert_response :bad_gateway
      assert_empty enqueued_jobs.select { |j| j[:job] == Cdp::OnrampPollJob },
                   "no CDP transaction can exist before the token mints — nothing to poll"
    end
  end

  test "onramp prefers the web3 address when one is linked" do
    with_cdp_ramp do
      give_managed_wallet
      @user.update!(web3_solana_address: "PhantomAddr#{SecureRandom.hex(4)}")
      log_in_as @user
      post_session(:onramp)
      assert_response :success

      ramp = CdpRampTransaction.last
      assert_equal @user.web3_solana_address, ramp.wallet_address
      assert ramp.wallet_web3?
    end
  end

  test "offramp from a web2 (email) session sources the managed wallet — server will sign" do
    with_cdp_ramp do
      give_managed_wallet
      @user.update!(web3_solana_address: "PhantomAddr#{SecureRandom.hex(4)}")
      log_in_as @user # email login → web2 session even though Phantom is linked

      post_session(:offramp)
      assert_response :success

      ramp = CdpRampTransaction.last
      assert ramp.offramp?
      assert ramp.wallet_web2?
      assert_equal @user.web2_solana_address, ramp.wallet_address
      assert JSON.parse(response.body)["url"].start_with?("https://pay.coinbase.com/v3/sell/input?")
    end
  end

  test "offramp from a Phantom session sources the web3 wallet — client will sign" do
    with_cdp_ramp do
      log_in_as_onchain @user # sets web3_solana_address + session[:onchain]

      post_session(:offramp)
      assert_response :success

      ramp = CdpRampTransaction.last
      assert ramp.wallet_web3?
      assert_equal @user.reload.web3_solana_address, ramp.wallet_address
    end
  end

  test "CDP mint failure → 502, ErrorLog with the ramp as target, row stays initiated" do
    with_cdp_ramp do
      give_managed_wallet
      log_in_as @user
      service = FakeTokenService.new(raise_error: Cdp::Client::ApiError.new("CDP 500: boom"))

      assert_difference "ErrorLog.count", 1 do
        post_session(:onramp, service: service)
      end
      assert_response :bad_gateway

      ramp = CdpRampTransaction.last
      assert ramp.initiated?, "a failed mint must leave a diagnosable initiated row"
      log = ErrorLog.last
      assert_equal "CdpRampTransaction", log.target_type
      assert_equal ramp.id, log.target_id
    end
  end

  test "CDP rate-limit → 429 so the client can back off" do
    with_cdp_ramp do
      give_managed_wallet
      log_in_as @user
      service = FakeTokenService.new(raise_error: Cdp::Client::RateLimitError.new("CDP 429: slow down"))
      post_session(:onramp, service: service)
      assert_response :too_many_requests
    end
  end

  test "onramp snapshots the wallet's USDC baseline for balance-anchored confirmation" do
    with_cdp_ramp do
      log_in_as @user
      give_managed_wallet
      post_session(:onramp, vault: FakeBalanceVault.new(usdc: 7.5))
      assert_response :success
      ramp = CdpRampTransaction.order(created_at: :desc).first
      assert_equal "7.5", ramp.raw_payload["baseline_usdc"]
    end
  end

  test "offramp does not snapshot a baseline" do
    with_cdp_ramp do
      log_in_as @user
      give_managed_wallet
      post_session(:offramp)
      assert_response :success
      ramp = CdpRampTransaction.order(created_at: :desc).first
      assert_nil ramp.raw_payload&.dig("baseline_usdc")
    end
  end

  test "preset_fiat prefills the widget URL when valid" do
    with_cdp_ramp do
      log_in_as @user
      give_managed_wallet
      post_session(:onramp, params: { preset_fiat: "19" })
      assert_response :success
      assert_includes JSON.parse(response.body)["url"], "presetFiatAmount=19"
    end
  end

  test "preset_fiat is dropped when malformed or out of range" do
    with_cdp_ramp do
      log_in_as @user
      give_managed_wallet
      [ "abc", "1", "9999", "19.999", "-5" ].each do |bad|
        post_session(:onramp, params: { preset_fiat: bad })
        assert_response :success
        refute_includes JSON.parse(response.body)["url"], "presetFiatAmount",
                        "expected preset #{bad.inspect} to be dropped"
      end
    end
  end
end
