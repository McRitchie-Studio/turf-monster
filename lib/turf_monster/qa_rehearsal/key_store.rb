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

      class AmbiguousItemError < StandardError; end

      # THE VAULT IS NOT INTERNALLY CONSISTENT ABOUT EITHER LABEL, and the two
      # spellings are not a tidy old/new split -- phantom.turf carries a spaced
      # "wallet address" beside a hyphenated "private-key". So both fields take
      # a LIST and the list is the contract; order is preference, not
      # precedence.
      #
      # ADDRESS WAS A SCALAR UNTIL 2026-09-15, and that is the exact shape of
      # bug this file exists to prevent. agent.turf.solana was refiled with
      # hyphenated labels, so a reader keyed to "wallet address" alone found
      # nothing on it -- and because an absent address SKIPPED the cross-check
      # below rather than failing it, the one guard that catches a key filed
      # under the wrong name would have switched itself off in silence, on the
      # one item whose filing had just changed.
      SECRET_FIELDS  = ["private key", "private-key"].freeze
      ADDRESS_FIELDS = ["wallet address", "wallet-address"].freeze

      # WHAT TO HAND `op`. A title is what a human types and what a reader
      # recognises, so it stays in the source either way; `id` is filled in only
      # where that title is not unique, because an ID alone documents nothing.
      Item = Struct.new(:title, :id, keyword_init: true) do
        # An ID is unambiguous; a title is a search. Prefer the pin when one
        # exists, but keep reporting the title -- an error naming a UUID sends
        # the reader to the wrong place.
        def locator
          id || title
        end

        def to_s
          title
        end
      end

      # Cast slug => 1Password item. Only wallets this rehearsal may act as.
      # Mr. McRitchie's own Phantom (7ZDJ…) is deliberately absent: it has no
      # filed key, and the human half of the settle is signed in a browser by
      # him, not here.
      #
      # THERE IS NO "alex"/"xan" CAST MEMBER, AND ADDING ONE BACK IS A MISTAKE.
      # The Xan wallet (8K81…, the identity this file called "Alex Bot" until
      # 2026-09-15) IS the fee payer and contest creator -- but the SERVER signs
      # as it from SOLANA_ADMIN_KEY on the dyno, never through this class, and
      # Driver::DEFAULT_CAST explains why it could not play even if it were
      # filed. On 2026-09-15 its item was renamed agent.xan.solana AND moved to
      # the studio-agents-admin vault, which this service account cannot read.
      # That inaccessibility is the control, not an oversight: it is what drops
      # an agent from 2-of-3 to 1-of-3 on both Squads multisigs. So repointing
      # this map at agent.xan.solana would only trade a not-found for a
      # permissions error, and "fixing" those permissions would quietly undo the
      # separation. The entry is gone; leave it gone.
      #
      # TWO TURF WALLETS, ON PURPOSE.
      #
      # "turf-admin" (agent.turf.solana, BLSBw8fX) is the turf-5 ADMIN account.
      # It drives the admin HTTP surface and cannot play: its username is the
      # reserved prefix "turf" and it has no on-chain UserAccount, so the
      # program refuses to register it (6020 UsernameReserved).
      #
      # It is also THE ONE ITEM PINNED BY ID. Two items in this vault carry the
      # exact title "agent.turf.solana": mczgzin… (both system wallets, the
      # hyphenated labels) and wriypyv… (the mainnet wallet only, spaced
      # labels). A title read matches both and `op` refuses with "More than one
      # item matches" -- a hard failure mid-rehearsal, for a reason no stack
      # trace explains. The pin is on the NEWER item, and BLSBw8fX is the same
      # wallet the older one held, so this resolves the ambiguity without
      # changing which key the rehearsal acts as. It also survives a human
      # deleting the duplicate, which is the point: vault tidying is not a
      # dependency of this code path.
      #
      # NOTE the pinned item also carries devnet-wallet-address /
      # devnet-private-key (2eGs8G3w…), a DIFFERENT wallet. SECRET_FIELDS and
      # ADDRESS_FIELDS deliberately do not name those labels. turf-5's on-chain
      # identity in QA is BLSBw8fX, so picking up the devnet pair would sign as
      # an account the app has never heard of.
      #
      # "turf" (phantom.turf, 39QTL1dd) is the PLAYER. Its UserAccount already
      # exists, which is the whole reason it works -- ensure_user_account
      # short-circuits on an existing account and never looks at the username.
      ITEMS = {
        "mason"      => Item.new(title: "agent.mason.solana"),
        "mack"       => Item.new(title: "agent.mack.solana"),
        "turf"       => Item.new(title: "phantom.turf"),
        "turf-admin" => Item.new(title: "agent.turf.solana",
                                 id: "mczgzinhh42mlltd6h4yvladhi")
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
        secret = SECRET_FIELDS.filter_map { |f| fields[f].presence }.first.to_s.strip
        if secret.empty?
          raise MissingKeyError,
                "1Password returned no #{SECRET_FIELDS.join(' / ')} field for #{item}"
        end

        keypair = decode(secret, item)

        # The item also carries the public address. Comparing the two is free
        # (same read) and it is the one check that catches a key filed under the
        # wrong name — a failure that would otherwise surface much later as an
        # on-chain constraint error naming a wallet nobody expected.
        #
        # AN ABSENT ADDRESS IS FATAL, not a skip. Every item this map can reach
        # files one, so "no address field" does not mean "this wallet has no
        # published address" — it means the label moved and this guard just
        # stopped guarding. Skipping quietly is strictly worse than the mismatch
        # it is here to catch: a mismatch is loud and a silent skip reads green.
        expected = ADDRESS_FIELDS.filter_map { |f| fields[f].presence }.first.to_s.strip
        if expected.empty?
          raise MissingKeyError,
                "#{item}: 1Password returned no #{ADDRESS_FIELDS.join(' / ')} field, so the " \
                "filed-address cross-check cannot run. The label has moved again — add the new " \
                "spelling to ADDRESS_FIELDS rather than signing with an unverified key."
        end

        if expected != keypair.to_base58
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
          "op", "item", "get", item.locator, "--vault", VAULT, "--format", "json"
        )
        unless status.success?
          message = err.to_s.strip

          # A COLLIDING TITLE GETS ITS OWN ERROR. `op` reports it as an ordinary
          # failure, so it would otherwise arrive as "op read failed" — which
          # reads like a missing item or a throttle and sends the reader to the
          # wrong remedy entirely. The fix is a code change here, and the error
          # should say so rather than implying someone must go tidy a vault.
          if message.match?(/more than one item matches/i)
            raise AmbiguousItemError,
                  "#{item}: more than one item in the #{VAULT} vault is titled #{item.title.inspect}. " \
                  "Pin the one this cast member means by id in KeyStore::ITEMS — " \
                  "`op item list --vault #{VAULT}` prints the ids."
          end

          # Otherwise surface 1Password's own stderr: a throttle reads as a
          # vault failure otherwise, and the two want different responses.
          raise MissingKeyError, "op read failed for #{item}: #{message}"
        end

        JSON.parse(out).fetch("fields", []).each_with_object({}) do |field, acc|
          label = field["label"] || field["id"]
          acc[label] = field["value"] if label && field["value"]
        end
      end
    end
  end
end
