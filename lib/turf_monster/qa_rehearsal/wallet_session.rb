# frozen_string_literal: true

require "net/http"
require "json"
require "uri"

module TurfMonster
  module QaRehearsal
    # An HTTP session that authenticates as a wallet, exactly the way the
    # browser does — because for this flow, nothing else works.
    #
    # `ContestsController#prepare_entry` refuses anything but a wallet-signed
    # session:
    #
    #     return render json: { error: "Phantom session required" },
    #                   status: :forbidden unless onchain_session?
    #
    # and `onchain_session?` is set in exactly one place: SolanaSessionsController
    # #verify, after a signature check. So the two obvious shortcuts both fail
    # by design, and it is worth writing down WHY so nobody re-tries them:
    #
    #   * A MAGIC LINK produces a web2 session. `session[:onchain]` stays unset,
    #     the app routes the user down the managed/server-sign path, and a
    #     Phantom-registered player has no server-held key for it.
    #   * ADMIN IMPERSONATION is worse — OPSEC-046 FORCES `onchain_session?` to
    #     false while impersonating, on the reasoning that an admin cannot
    #     produce the target's signature. This driver can, which is the whole
    #     point, but the session flag does not care how the signature was made.
    #
    # So: nonce, message, signature, verify. Same four steps, same endpoints,
    # same verifier. The only difference from a browser is where the key lives.
    class WalletSession
      class HttpError < StandardError; end
      class SignInError < StandardError; end

      NONCE_PATH  = "/auth/solana/nonce"
      VERIFY_PATH = "/auth/solana/verify"

      attr_reader :host, :cookies, :keypair

      # @param host [String] host_with_port, e.g. "turf-monster-qa.herokuapp.com".
      #   This is also what gets baked into the signed message, so it MUST equal
      #   what the server sees as request.host_with_port — a signature made
      #   against the wrong name fails the OPSEC-018 host binding.
      # @param keypair [Solana::Keypair]
      # @param scheme [String]
      def initialize(host:, keypair:, scheme: "https")
        @host = host
        @keypair = keypair
        @scheme = scheme
        @cookies = {}
        @csrf_token = nil
      end

      def address
        @keypair.to_base58
      end

      # Performs the full wallet sign-in. Returns the parsed verify response.
      def sign_in!(wallet_provider: "phantom")
        # The nonce is stored in the SESSION, so this GET and the POST below
        # must share a cookie jar. They do — that is what @cookies is for — and
        # a driver that forgot it would see "No nonce provided" rather than
        # anything pointing at cookies.
        nonce = get_json(NONCE_PATH).fetch("nonce")

        message = SignInMessage.build(host: host, pubkey: address, nonce: nonce)
        signature = Solana::Keypair.encode_base58(@keypair.sign(message))

        response = post_json(VERIFY_PATH,
          message: message,
          signature: signature,
          pubkey: address,
          wallet_provider: wallet_provider)

        if response["error"].present?
          raise SignInError, "wallet sign-in refused for #{address}: #{response['error']}"
        end

        response
      end

      # Clears the entry-time age gate (ENABLE_AGE_GATE), which sits directly
      # BEHIND the wallet-session check in prepare_entry — so a cast member with
      # a valid on-chain session still cannot enter until this is stamped once.
      # POSTing it is the browser-faithful move: the DOB modal in the contest
      # hold-to-confirm flow hits this same endpoint, and the server recomputes
      # the age against the DETECTED state rather than anything sent here.
      # Idempotent in effect — a second call just re-stamps the same columns.
      def verify_age!(dob: "1980-01-01")
        response = post_json("/age/verify", date_of_birth: dob)
        return response if response["verified"]

        raise SignInError, "age verification refused for #{address}: #{response['error'] || response.inspect}"
      end

      def get_json(path)
        parse_json(request(Net::HTTP::Get, path))
      end

      def post_json(path, **params)
        parse_json(request(Net::HTTP::Post, path, params))
      end

      # Rails' forgery protection is on by default in this app (no
      # skip_forgery_protection anywhere), so a POST needs the same
      # <meta name="csrf-token"> value a page would carry. Fetched once, from a
      # cheap page, under the same cookie jar the token is bound to.
      def csrf_token
        @csrf_token ||= begin
          body = request(Net::HTTP::Get, "/").body.to_s
          body[/<meta name="csrf-token" content="([^"]+)"/, 1]
        end
      end

      private

      # Follows redirects on reads, because the app uses them for real routing —
      # `/` 302s to the featured contest, and a client that stopped there would
      # read an empty body and conclude the page carries no CSRF token. Bounded,
      # and only for GET: a redirected POST would silently drop its body.
      MAX_REDIRECTS = 5

      def request(verb, path, params = nil, redirects_left = MAX_REDIRECTS)
        # Resolve the CSRF token BEFORE stamping the Cookie header. Fetching it
        # issues its own GET, and that GET can rotate the session cookie — so a
        # header written first would send the OLD session alongside a token
        # minted for the NEW one. Rails rejects that pairing as an invalid
        # authenticity token and the app answers 500, which reads like a server
        # fault rather than a client ordering mistake. It cost a confusing
        # "Internal server error" on the second run of this driver to find.
        token = params ? csrf_token : nil

        uri = URI("#{@scheme}://#{host}#{path}")
        req = verb.new(uri)
        req["Accept"] = "application/json, text/html"
        req["Cookie"] = cookie_header if cookies.any?

        if params
          req["Content-Type"] = "application/json"
          req["X-CSRF-Token"] = token if token
          req["X-Requested-With"] = "XMLHttpRequest"
          req.body = params.to_json
        end

        response = Net::HTTP.start(uri.host, uri.port, use_ssl: uri.scheme == "https") do |http|
          http.request(req)
        end

        absorb_cookies(response)

        if params.nil? && response.is_a?(Net::HTTPRedirection) && redirects_left.positive?
          location = response["location"].to_s
          return request(verb, URI(location).request_uri, nil, redirects_left - 1) if location.present?
        end

        response
      end

      # Session continuity is the whole game here, so cookies are merged rather
      # than replaced: Rails re-issues the session cookie on sign-in, and a jar
      # that dropped everything else would lose the CSRF binding with it.
      def absorb_cookies(response)
        Array(response.get_fields("Set-Cookie")).each do |raw|
          name, value = raw.split(";").first.to_s.split("=", 2)
          @cookies[name] = value if name && value
        end
      end

      def cookie_header
        cookies.map { |k, v| "#{k}=#{v}" }.join("; ")
      end

      def parse_json(response)
        body = response.body.to_s
        return {} if body.empty?

        JSON.parse(body)
      rescue JSON::ParserError
        raise HttpError, "expected JSON from #{response.uri}, got #{response.code}: #{body[0, 200]}"
      end
    end
  end
end
