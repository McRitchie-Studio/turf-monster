require "net/http"
require "openssl"

module Aeropay
  # Direct REST client for Aeropay's bank-payment (pay-by-bank ACH + RTP) API +
  # the webhook signature check. There is no Ruby Aeropay SDK, so this is plain
  # Net::HTTP, instrumented through OutboundRequestLogger (service: "aeropay")
  # the same way Coinflow::Client / Paypal::Client are — success AND failure
  # both land in outbound_requests for forensics.
  #
  # ── Contract (ALL fields FLAGGED — built to dev.aero.inc/docs without a live
  #    sandbox; verify every request/response field against the real sandbox
  #    once the operator's merchant creds land) ──────────────────────────────
  #   Base:  ENV["AEROPAY_API_BASE"] || "https://api.sandbox-pay.aero.inc/v2"
  #          (prod: "https://api.aeropay.com/v2")   [FLAG: exact hostnames — dev.aero.inc/docs]
  #   Auth:  Authorization: Bearer <AEROPAY_API_TOKEN>
  #          Content-Type: application/json
  #          Idempotency-Key: <uuid>   (optional, per-request)
  #
  #   POST /v2/transaction            — create a deposit (buy entry). [FLAG: dev.aero.inc/docs/transactions]
  #     Body: { amount: "19.00", currency: "USD", bankAccountId:, externalId:,
  #             paymentRail: "instant", merchantId: }
  #     -> { "id": "<transactionId>", "status": "pending"|"completed"|... }
  #   GET  /v2/linkAccountFromAggregator  — exchange the front-end Aerosync token
  #                                          for a linked bank account. [FLAG: dev.aero.inc/docs/aerosync]
  #   GET  /v2/bankAccounts               — list a customer's linked accounts. [FLAG]
  #   POST /v2/payoutTransaction          — withdrawals (NOT this task; follow-up).
  #
  # Aeropay's flow is BANK rails, not a hosted-redirect: the buyer links a bank
  # via the front-end Aerosync widget (which needs real merchant creds to load —
  # stubbed until they land, see tokens/_aeropay_script), the server exchanges
  # that into a bankAccountId, then creates the deposit. On the
  # `transaction_completed` webhook we mint exactly 1 entry token.
  #
  # SETTLEMENT CAVEAT: a `transaction_completed` for an ACH pay-in is APPROVED,
  # not SETTLED (funds are final ~3 business days later). We mirror Coinflow's
  # Settled→mint (mint on `transaction_completed`); PRODUCTION should prefer the
  # instant RfP/RTP pay-in path (paymentRail: "instant", irrevocable) so funds
  # are final before the on-chain mint. [FLAG: confirm the instant-rail field +
  # value against dev.aero.inc/docs/transactions.]
  class Client
    Error = Class.new(StandardError)

    # [FLAG] Aeropay base hosts + the /v2 version segment — dev.aero.inc/docs.
    DEFAULT_BASE = "https://api.sandbox-pay.aero.inc/v2".freeze
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30

    class << self
      def base_url
        ENV.fetch("AEROPAY_API_BASE", DEFAULT_BASE)
      end

      # Sandbox tell for the OPSEC-033 production guard (CoinflowController
      # parity): the configured API host is an Aeropay sandbox host.
      def sandbox?
        base_url.to_s.include?("sandbox")
      end
    end

    # POST /v2/transaction — create the deposit that buys the entry. The amount
    # derives SERVER-SIDE from the pack definition (never the client); the caller
    # only ever names a pack + the linked bankAccountId. `externalId` carries our
    # reference so `transaction_completed` resolves back to the exact row.
    #
    # [FLAG] Amount representation: assumed DECIMAL DOLLARS string ("19.00") + a
    # top-level "USD" currency. If the sandbox reports/accepts CENTS instead,
    # capture_matches? fails closed (never mints) and this body under-charges —
    # verify against dev.aero.inc/docs/transactions FIRST when creds land.
    def create_deposit(user:, pack:, bank_account_id:, reference:, idempotency_key: nil)
      body = {
        amount:        self.class.dollars_string(Integer(pack.fetch(:price_cents))),
        currency:      "USD",
        bankAccountId: bank_account_id,
        externalId:    reference,
        # [FLAG] Prefer the instant (RfP/RTP) irrevocable pay-in over standard
        # ACH (which stays "Pending" ~3 business days). Field/value assumed.
        paymentRail:   "instant",
        merchantId:    ENV["AEROPAY_MERCHANT_ID"]
      }.compact
      response = request(:post, "/transaction", body: body, idempotency_key: idempotency_key)
      transaction_id = self.class.transaction_id(response)
      raise Error, "Aeropay transaction id missing from response" if transaction_id.blank?
      # Normalize to a stable shape the caller can trust regardless of the raw
      # envelope (top-level vs nested under "data").
      { "id" => transaction_id, "status" => self.class.transaction_status(response), "raw" => response }
    end

    # GET /v2/linkAccountFromAggregator — exchange the front-end Aerosync
    # widget's aggregator token for a linked Aeropay bank account. The real
    # order flow calls this BEFORE create_deposit once the widget can load
    # (needs merchant creds). [FLAG: exact query param + response shape.]
    def link_account_from_aggregator(token:)
      request(:get, "/linkAccountFromAggregator", query: { token: token })
    end

    # GET /v2/bankAccounts — list a customer's linked bank accounts. [FLAG.]
    def bank_accounts(customer_id: nil)
      request(:get, "/bankAccounts", query: { customerId: customer_id }.compact)
    end

    # Aeropay authenticates its webhook with an HMAC signature over the RAW
    # request body, keyed by AEROPAY_WEBHOOK_SIGNING_KEY. Fail closed (false)
    # when the key is unset or the signature header is blank, and use a
    # constant-time compare so a timing side-channel can't probe the digest.
    #
    # [FLAG] Signature scheme ASSUMED: hex-encoded HMAC-SHA256 of the exact raw
    # body, delivered in the X-Aeropay-Signature header. Coinflow authenticates
    # its webhook with a shared secret; Aeropay's is unconfirmed — CONFIRM the
    # exact algorithm, encoding, and header name against
    # dev.aero.inc/docs/webhooks-1 when creds land. If Aeropay turns out to use
    # a shared-secret header (like Coinflow) or a signed-prefix scheme (like
    # Stripe's t=..,v1=..), swap this body accordingly.
    def verify_webhook(raw_body, signature)
      key = ENV["AEROPAY_WEBHOOK_SIGNING_KEY"].to_s
      if key.blank?
        Rails.logger.warn "[tokens] aeropay.verify_skipped AEROPAY_WEBHOOK_SIGNING_KEY not set"
        return false
      end
      return false if signature.to_s.empty?
      expected = OpenSSL::HMAC.hexdigest("SHA256", key, raw_body.to_s)
      ActiveSupport::SecurityUtils.secure_compare(signature.to_s, expected)
    end

    # Integer cents → the decimal-dollars string Aeropay expects. [FLAG.]
    def self.dollars_string(cents)
      format("%.2f", Integer(cents) / 100.0)
    end

    # [FLAG] Pull the transaction id out of the response envelope — top-level
    # "id" assumed, falling back to a nested "data" object.
    def self.transaction_id(response)
      return nil unless response.is_a?(Hash)
      (response["id"] || response.dig("data", "id") || response["transactionId"]).presence
    end

    def self.transaction_status(response)
      return nil unless response.is_a?(Hash)
      response["status"] || response.dig("data", "status")
    end

    private

    # Single instrumented entrypoint for every Aeropay HTTP call (Coinflow /
    # Paypal Client#request parity). OutboundRequestLogger sanitizes bodies; the
    # "authorization" / "token" / "secret" sensitive-key rules redact credentials.
    def request(http_method, path, body: nil, query: nil, idempotency_key: nil)
      started = Time.current
      response = nil
      error = nil

      begin
        response = perform(http_method, path, body: body, query: query, idempotency_key: idempotency_key)
        parsed = parse_body(response)
        unless response.code.to_i.between?(200, 299)
          message = (parsed["message"] || parsed["error"] || response.body.to_s[0, 300])
          raise Error, "Aeropay #{http_method.to_s.upcase} #{path} → #{response.code}: #{message}"
        end
        parsed
      rescue => e
        error = e
        raise
      ensure
        record_outbound(http_method, path, body, response, started, error)
      end
    end

    def perform(http_method, path, body:, query:, idempotency_key:)
      uri = build_uri(path, query)
      req =
        case http_method
        when :get  then Net::HTTP::Get.new(uri)
        when :post then Net::HTTP::Post.new(uri)
        else raise ArgumentError, "unsupported HTTP method #{http_method}"
        end

      req["Authorization"] = "Bearer #{ENV['AEROPAY_API_TOKEN']}"
      req["Idempotency-Key"] = idempotency_key if idempotency_key.present?
      if body
        req["Content-Type"] = "application/json"
        req.body = body.to_json
      end

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.request(req)
    end

    # The base_url already carries the /v2 version segment, so join with a plain
    # concat (URI.join would DISCARD the /v2 path when the endpoint has a leading
    # slash). File.join collapses the seam to exactly one slash.
    def build_uri(path, query = nil)
      url = File.join(self.class.base_url, path.to_s.sub(%r{\A/+}, ""))
      url += "?#{URI.encode_www_form(query)}" if query.present?
      URI(url)
    end

    def parse_body(response)
      return {} if response.body.blank?
      JSON.parse(response.body)
    rescue JSON::ParserError
      { "_raw" => response.body.to_s[0, 300] }
    end

    def record_outbound(http_method, path, request_body, response, started, error)
      OutboundRequestLogger.record!(
        service:       "aeropay",
        method:        http_method.to_s.upcase,
        endpoint:      path,
        request_body:  request_body,
        response_body: response&.body,
        status_code:   response&.code&.to_i,
        duration_ms:   ((Time.current - started) * 1000).round,
        error_class:   error&.class&.to_s,
        error_message: error&.message
      )
    rescue => log_err
      Rails.logger.error "[outbound_request_logger] aeropay hook failed: #{log_err.message}"
    end
  end
end
