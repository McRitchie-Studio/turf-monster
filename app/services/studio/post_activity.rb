require "net/http"
require "json"

module Studio
  # Writes ONE activity row to the McRitchie Studio hub's feed (POST
  # /api/v1/activities). The hub stamps the author from this app's runtime key
  # (the turf-monster client soul), whatever the body says.
  #
  # Used for the record of an action the platform completed with its own two
  # signatures (Solana::PlatformCosigner): the PendingTransaction row is the
  # system of record, and this is the copy the operators read in the hub.
  #
  # BEST EFFORT, AND IT SAYS WHICH. A hub that is down or refuses must never
  # undo or block a transaction that already landed, so #call never raises: it
  # returns "posted" or a short reason, and the caller writes that onto the row.
  class PostActivity
    DEFAULT_BASE_URL = PushGameRecap::DEFAULT_BASE_URL
    OPEN_TIMEOUT = 5
    READ_TIMEOUT = 10
    CALLER = "turf-monster/post_activity".freeze
    ACTIVITY_TYPE = "platform_cosign".freeze

    def self.call(description:, metadata: {}, **opts)
      new(**opts).call(description: description, metadata: metadata)
    end

    def initialize(base_url: nil, runtime_key: nil, secret: nil, http: nil)
      @base_url = (base_url || ENV["STUDIO_API_BASE"].presence || DEFAULT_BASE_URL).chomp("/")
      @runtime_key = runtime_key || HubCredential.runtime_key
      @secret = secret || (HubCredential.secret unless @runtime_key)
      @http = http
    end

    def call(description:, metadata: {})
      return "not posted: #{HubCredential::MISSING}" if @runtime_key.blank? && @secret.blank?

      token = @runtime_key.presence || authenticate
      post_json("/api/v1/activities",
                { activity_type: ACTIVITY_TYPE, description: description, metadata: metadata }, token: token)
      "posted"
    rescue StandardError => e
      Rails.logger.warn("[post-activity] hub activity not posted (#{e.class}: #{e.message.to_s[0, 160]})")
      "not posted: #{e.class.name.demodulize} #{e.message.to_s[0, 120]}"
    end

    private

    def authenticate
      token = post_json("/api/v1/auth", { secret: @secret }, token: nil)["token"]
      raise "no token in auth response" if token.blank?

      token
    end

    def post_json(path, body, token:)
      uri = URI("#{@base_url}#{path}")
      http = @http || Net::HTTP.new(uri.host, uri.port).tap do |h|
        h.use_ssl = uri.scheme == "https"
        h.open_timeout = OPEN_TIMEOUT
        h.read_timeout = READ_TIMEOUT
      end

      request = Net::HTTP::Post.new(uri.request_uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json"
      request["Authorization"] = "Bearer #{token}" if token
      request[HubCredential::CALLER_HEADER] = CALLER
      request.body = body.to_json

      response = http.request(request)
      # The status only: the auth call's body IS the shared secret's answer.
      raise "studio #{path} returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

      JSON.parse(response.body.to_s)
    end
  end
end
