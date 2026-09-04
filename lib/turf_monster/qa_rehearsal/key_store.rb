# frozen_string_literal: true

require "json"

module TurfMonster
  module QaRehearsal
    # Loads a cast member's Solana keypair from 1Password.
    #
    # Three rules, each of which cost something to learn:
    #
    #   * READ ONCE PER PROCESS, and read BOTH fields in that one call. The
    #     1Password daily request cap is ACCOUNT-WIDE, shared by every service
    #     account and lane, so a driver that re-reads per step can exhaust a
    #     quota that has nothing to do with this rehearsal.
    #   * ACCEPT BOTH KEY FORMATS. The vault is not internally consistent:
    #     `agent.mason.solana` holds an 88-character base58 secret, while
    #     `agent.turf.solana` holds a Solana-CLI JSON byte array. A loader that
    #     assumed either one fails on the other with "Invalid base58 character",
    #     which reads like a corrupt key rather than a second valid encoding.
    #   * NEVER RETURN OR LOG THE SECRET. Callers get a Solana::Keypair and can
    #     ask it for a public key; the secret never leaves this file.
    #
    # The caller is expected to have satisfied NetworkGuard first. This class
    # does not check — one object, one job — but nothing should construct it on
    # a code path where the guard has not already passed.
    class KeyStore
      class MissingKeyError < StandardError; end
      class KeyMismatchError < StandardError; end

      VAULT = "studio-agents"
      SECRET_FIELD  = "private key"
      ADDRESS_FIELD = "wallet address"

      # Cast slug => 1Password item. Only wallets this rehearsal may act as.
      # Mr. McRitchie's own Phantom (7ZDJ…) is deliberately absent: it has no
      # filed key, and the human half of the settle is signed in a browser by
      # him, not here.
      #
      # "alex" is the ALEX BOT wallet — the same key the server signs with as
      # fee payer and contest creator. It is listed because it is a real filed
      # wallet the driver may need to act as, but see Driver::DEFAULT_CAST for
      # why it does not play.
      ITEMS = {
        "mason" => "agent.mason.solana",
        "mack"  => "agent.mack.solana",
        "turf"  => "agent.turf.solana",
        "alex"  => "agent.alex.solana"
      }.freeze

      def initialize(runner: nil)
        @runner = runner || method(:op_read_item)
        @cache = {}
      end

      # @param who [String] a key of ITEMS
      # @return [Solana::Keypair]
      def keypair(who)
        slug = who.to_s
        item = ITEMS.fetch(slug) do
          raise MissingKeyError, "no filed key for #{slug.inspect} (known: #{ITEMS.keys.join(', ')})"
        end

        @cache[slug] ||= load_keypair(item)
      end

      # Public addresses only — safe to print, and the driver does print them so
      # the operator can see which wallets a run will move.
      def address(who)
        keypair(who).to_base58
      end

      private

      def load_keypair(item)
        fields = @runner.call(item)
        secret = fields[SECRET_FIELD].to_s.strip
        raise MissingKeyError, "1Password returned no #{SECRET_FIELD.inspect} for #{item}" if secret.empty?

        keypair = decode(secret, item)

        # The item also carries the public address. Comparing the two is free
        # (same read) and it is the one check that catches a key filed under the
        # wrong name — a failure that would otherwise surface much later as an
        # on-chain constraint error naming a wallet nobody expected.
        expected = fields[ADDRESS_FIELD].to_s.strip
        if expected.present? && expected != keypair.to_base58
          raise KeyMismatchError,
                "#{item}: filed address #{expected} does not match the key's own #{keypair.to_base58}"
        end

        keypair
      end

      # A Solana CLI keypair is a JSON array of 64 bytes; an env-style secret is
      # base58. Dispatch on the first character rather than by rescuing a parse
      # failure, so a genuinely corrupt value still raises its own error.
      def decode(secret, item)
        if secret.start_with?("[")
          Solana::Keypair.from_bytes(JSON.parse(secret))
        else
          Solana::Keypair.from_base58(secret)
        end
      rescue JSON::ParserError, ArgumentError => e
        raise MissingKeyError, "#{item}: could not decode the stored key (#{e.class})"
      end

      def op_read_item(item)
        require "open3"
        out, err, status = Open3.capture3(
          "op", "item", "get", item, "--vault", VAULT, "--format", "json"
        )
        unless status.success?
          # Surface 1Password's own stderr: a throttle reads as a vault failure
          # otherwise, and the two want different responses.
          raise MissingKeyError, "op read failed for #{item}: #{err.to_s.strip}"
        end

        JSON.parse(out).fetch("fields", []).each_with_object({}) do |field, acc|
          label = field["label"] || field["id"]
          acc[label] = field["value"] if label && field["value"]
        end
      end
    end
  end
end
