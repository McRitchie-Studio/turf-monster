require "net/http"

module Coinflow
  # Direct REST client for Coinflow's hosted-checkout link API + the webhook
  # shared-secret check. There is no Ruby Coinflow SDK, so this is plain
  # Net::HTTP, instrumented through OutboundRequestLogger (service: "coinflow")
  # the same way Paypal::Client is — success AND failure both land in
  # outbound_requests for forensics.
  #
  # Contract (sandbox, docs.coinflow.cash):
  #   Base:  ENV["COINFLOW_API_BASE"] || "https://api-sandbox.coinflow.cash"
  #   POST /api/checkout/link
  #     Headers: Authorization: <COINFLOW_API_KEY>,
  #              x-coinflow-auth-user-id: <stable per-user id>,
  #              Content-Type: application/json
  #     Body:    { subtotal: { cents:, currency: "USD" },
  #                chargebackProtectionData: [{ productName:, productType:,
  #                                             quantity:, rawProductData: }],
  #                email:,   # omitted when the buyer has none
  #                standaloneLinkConfig: { callbackUrl:, endUserDeviceIpAddress: } }
  #     -> { "link": "https://sandbox-merchant.coinflow.cash/purchase-v2/..." }
  #
  # Coinflow's flow is a redirect + webhook — no client-side capture leg like
  # PayPal's onApprove. On the `Settled` webhook we mint exactly 1 entry token.
  class Client
    Error = Class.new(StandardError)

    DEFAULT_BASE = "https://api-sandbox.coinflow.cash".freeze
    OPEN_TIMEOUT = 10
    READ_TIMEOUT = 30

    # Payment methods shown on the hosted checkout, in order. Coinflow shows ALL
    # available methods when this is omitted; passing an explicit list hides
    # everything not named — so this keeps the consumer rails (Apple Pay + Google
    # Pay wallet buttons, then card + PayPal + Venmo) and drops the rest of the
    # "or" grid (no bank/wire/SEPA/crypto/Cash App/APA/Interac). Enum strings per
    # docs.coinflow.cash checkout-link API. NOTE: Apple/Google Pay render only on
    # a supporting device/browser; PayPal/Venmo also require account-level
    # enablement by Coinflow's integrations team, Venmo is US-only; `card` is ungated.
    ALLOWED_PAYMENT_METHODS = %w[applePay googlePay card paypal venmo].freeze

    # Cart description for Coinflow's Chargeback Protection underwriter, sent as
    # the top-level `chargebackProtectionData` array. REQUIRED once the merchant
    # account has chargeback protection enabled — and the failure is late and
    # confusing: Coinflow still answers the create-link call 200 without it, then
    # the HOSTED checkout page refuses the buyer's Confirm Purchase with
    # "chargebackProtectionData is required". `productType` is Coinflow's enum;
    # `gameOfSkill` is the honest classification for a Turf Monster entry token
    # (skill-based contests), and the underwriter prices against it.
    PRODUCT_NAME = "Turf Monster entry token".freeze
    PRODUCT_TYPE = "gameOfSkill".freeze

    class << self
      def base_url
        ENV.fetch("COINFLOW_API_BASE", DEFAULT_BASE)
      end

      # Sandbox tell for the OPSEC-033 production guard (PaypalController
      # parity): the configured API host is a Coinflow sandbox host.
      def sandbox?
        base_url.to_s.include?("sandbox")
      end
    end

    # POST /api/checkout/link. Amount derives SERVER-SIDE from the pack
    # definition (integer cents) — the caller only ever names a pack. The
    # x-coinflow-auth-user-id is a stable per-user handle so Coinflow's webhook
    # can echo it back as customerId; the purchase reference rides the
    # callbackUrl so the settlement resolves to the exact row.
    def create_checkout_link(user:, pack:, pack_id:, return_url:, ip:)
      body = {
        subtotal: { cents: Integer(pack.fetch(:price_cents)), currency: "USD" },
        allowedPaymentMethods: ALLOWED_PAYMENT_METHODS,
        chargebackProtectionData: [
          {
            productName: PRODUCT_NAME,
            productType: PRODUCT_TYPE,
            quantity: Integer(pack.fetch(:quantity)),
            rawProductData: {
              packId: pack_id.to_s,
              priceCents: Integer(pack.fetch(:price_cents))
            }
          }
        ],
        standaloneLinkConfig: {
          callbackUrl: return_url,
          endUserDeviceIpAddress: ip
        }
      }
      # Identity signal for the underwriter — Coinflow's acceptance-rate guidance
      # asks for email, name, and device behavior. Email is the ONLY one of those
      # we hold for every buyer (first_name/last_name exist on users but are not
      # reliably populated), so send it alone rather than a half-filled
      # customerInfo. Omit the key entirely when blank: never send `email: null`.
      body[:email] = user.email if user.email.present?

      response = request(:post, "/api/checkout/link", body: body,
                         headers: { "x-coinflow-auth-user-id" => self.class.auth_user_id(user) })
      link = response["link"]
      raise Error, "Coinflow checkout link missing from response" if link.blank?
      link
    end

    # Coinflow authenticates its webhook with a SHARED SECRET, not an HMAC: the
    # request's Authorization header must equal COINFLOW_WEBHOOK_VALIDATION_KEY.
    # Fail closed (false) when the key is unset or the header is blank, and use
    # a constant-time compare so a timing side-channel can't probe the secret.
    def verify_webhook_auth(header)
      expected = ENV["COINFLOW_WEBHOOK_VALIDATION_KEY"].to_s
      if expected.blank?
        Rails.logger.warn "[tokens] coinflow.verify_skipped COINFLOW_WEBHOOK_VALIDATION_KEY not set"
        return false
      end
      return false if header.to_s.empty?
      ActiveSupport::SecurityUtils.secure_compare(header.to_s, expected)
    end

    # Stable per-user id sent as x-coinflow-auth-user-id and echoed back as the
    # webhook's customerId. Keyed on the DB id so settlement resolves to the
    # right user (Webhooks::CoinflowController#purchase_for_event tier 3).
    def self.auth_user_id(user)
      "tm_user_#{user.id}"
    end

    private

    # Single instrumented entrypoint for every Coinflow HTTP call (Paypal::Client
    # #request parity). OutboundRequestLogger sanitizes bodies; the "authorization"
    # / "api_key" sensitive-key rules redact the credential headers.
    def request(http_method, path, body: nil, headers: {})
      started = Time.current
      response = nil
      error = nil

      begin
        response = perform(http_method, path, body: body, headers: headers)
        parsed = parse_body(response)
        unless response.code.to_i.between?(200, 299)
          message = parsed["message"] || parsed["error"] || response.body.to_s[0, 300]
          raise Error, "Coinflow #{http_method.to_s.upcase} #{path} → #{response.code}: #{message}"
        end
        parsed
      rescue => e
        error = e
        raise
      ensure
        record_outbound(http_method, path, body, response, started, error)
      end
    end

    def perform(http_method, path, body:, headers:)
      uri = URI.join(self.class.base_url, path)
      req =
        case http_method
        when :get  then Net::HTTP::Get.new(uri)
        when :post then Net::HTTP::Post.new(uri)
        else raise ArgumentError, "unsupported HTTP method #{http_method}"
        end

      req["Authorization"] = ENV["COINFLOW_API_KEY"].to_s
      if body
        req["Content-Type"] = "application/json"
        req.body = body.to_json
      end
      headers.each { |key, value| req[key] = value }

      http = Net::HTTP.new(uri.host, uri.port)
      http.use_ssl = (uri.scheme == "https")
      http.open_timeout = OPEN_TIMEOUT
      http.read_timeout = READ_TIMEOUT
      http.request(req)
    end

    def parse_body(response)
      return {} if response.body.blank?
      JSON.parse(response.body)
    rescue JSON::ParserError
      { "_raw" => response.body.to_s[0, 300] }
    end

    def record_outbound(http_method, path, request_body, response, started, error)
      OutboundRequestLogger.record!(
        service:       "coinflow",
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
      Rails.logger.error "[outbound_request_logger] coinflow hook failed: #{log_err.message}"
    end
  end
end
