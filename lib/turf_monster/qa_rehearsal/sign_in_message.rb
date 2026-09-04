# frozen_string_literal: true

module TurfMonster
  module QaRehearsal
    # Builds the exact message a wallet signs at sign-in, so an agent holding a
    # keypair can authenticate over HTTP the way a browser does.
    #
    # This string is a CONTRACT, not a convenience. The server verifies it in
    # Solana::AuthVerifier.verify! (solana-studio), which imposes three
    # separate conditions on the text itself:
    #
    #   1. It MUST begin with "<host> " — OPSEC-018 binds the signature to the
    #      domain, so a signature made for another dApp cannot be replayed here.
    #      The host is `request.host_with_port`: hostname, plus the port only
    #      when non-default.
    #   2. It MUST contain "Nonce: <value>" matching the nonce the server just
    #      issued and stored in the session, and the server DELETES that nonce
    #      before verifying — one message, one use.
    #   3. When the caller is already authenticated, it MUST embed
    #      "User-ID: <id>" (OPSEC-005). Sign-in itself has no current_user, so
    #      the login form omits it.
    #
    # The literal below is byte-identical to what the browser signs — see
    # `app/views/layouts/application.html.erb` (the connect + signMessage
    # fallback) and `app/javascript/solana_stores.js`. Keep them in step: a
    # message that differs by one character still signs fine and then fails
    # verification with "Message is not bound to host", which reads like a
    # configuration problem rather than a text problem.
    module SignInMessage
      STATEMENT = "Sign in to Turf Monster"

      # @param host [String] host_with_port the server will compare against
      # @param pubkey [String] base58 public key doing the signing
      # @param nonce [String] value from GET /auth/solana/nonce
      # @param user_id [Integer, nil] only for already-authenticated flows
      # @return [String] the message to sign, verbatim
      def self.build(host:, pubkey:, nonce:, user_id: nil)
        raise ArgumentError, "host required" if host.to_s.strip.empty?
        raise ArgumentError, "pubkey required" if pubkey.to_s.strip.empty?
        raise ArgumentError, "nonce required" if nonce.to_s.strip.empty?

        user_id_line = user_id ? "User-ID: #{user_id}\n\n" : ""

        "#{host} wants you to sign in with your Solana account:\n" \
          "#{pubkey}\n\n" \
          "#{user_id_line}#{STATEMENT}\n\n" \
          "Nonce: #{nonce}"
      end
    end
  end
end
