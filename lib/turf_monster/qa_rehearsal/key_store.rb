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
    #   * ACCEPT BOTH KEY FORMATS. `agent.mason.solana` holds an 88-character
    #     base58 secret; a Solana-CLI export is a JSON array of 64 bytes
    #     instead. A loader that assumed either one fails on the other with
    #     "Invalid base58 character", which reads like a corrupt key rather
    #     than a second valid encoding. Every item ITEMS can reach files base58
    #     as of 2026-09-15, so the JSON branch is DEFENSIVE today rather than
    #     load-bearing -- kept because this vault was restructured three times
    #     in one day and the branch costs four lines.
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
      # bug this file exists to prevent. The turf keys were refiled with
      # hyphenated labels -- all three solana.turf.* items spell them
      # `wallet-address` / `private-key` -- so a reader keyed to "wallet
      # address" alone found nothing on them. And because an absent address
      # SKIPPED the cross-check below rather than failing it, the one guard that
      # catches a key filed under the wrong name would have switched itself off
      # in silence, on the very items whose filing had just changed.
      SECRET_FIELDS  = ["private key", "private-key"].freeze
      ADDRESS_FIELDS = ["wallet address", "wallet-address"].freeze

      # WHAT TO HAND `op`. A title is what a human types and what a reader
      # recognises, so it stays in the source either way; `id` is filled in only
      # where that title is not unique, because an ID alone documents nothing.
      Item = Struct.new(:title, :id, keyword_init: true) do
        # An ID is unambiguous; a title is a search. Prefer the pin when one
        # exists, but keep reporting the title -- an error naming a UUID sends
        # the reader to the wrong place. NO slug sets an id today, and ITEMS
        # explains at length why the last one was removed rather than repointed.
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
      # Xan (8K81…, the identity this file called "Alex Bot" until 2026-09-15)
      # is the fee payer and contest creator -- but the SERVER signs as it from
      # SOLANA_ADMIN_KEY on the dyno, never through this class, and
      # Driver::DEFAULT_CAST explains why it could not play even if it were
      # filed. Its item is agent.xan.solana in the studio-agents-admin vault,
      # which this service account cannot read. The entry is gone; leave it gone.
      #
      # PINNED BY TITLE, NOT BY ID -- and the id pin this replaces is why.
      #
      # Until 2026-09-15 "turf-admin" was pinned to item id
      # mczgzinhh42mlltd6h4yvladhi, because two items then shared the title
      # "agent.turf.solana" and a title read failed with "More than one item
      # matches". Mr. McRitchie then RECREATED the turf keys under unique,
      # role-specific titles -- and a recreated item gets a NEW id, so the pin
      # resolved to an item that no longer existed and every turf-admin read
      # failed outright. An id is only unambiguous while the OBJECT survives;
      # it does not survive a re-file, which is the act that keeps happening.
      #
      # AN ID PIN ALSO DISARMS AmbiguousItemError. `op item get <id>` resolves
      # directly and can never report a collision, so the guard in
      # #op_read_item is unreachable for any slug pinned by id. Pinning by
      # title is what keeps that guard armed -- "pin by id and keep the guard"
      # would keep a guard that cannot fire.
      #
      # The two failures are asymmetric in the right direction. A collision
      # raises AmbiguousItemError, which names the item, the vault, and the
      # fix. A dead id is a bare not-found: no remedy in the message, and the
      # replacement id discoverable only by listing the vault. The titles below
      # were verified unique in studio-agents on 2026-09-15 (`op item list`),
      # and the new scheme is unique BY CONSTRUCTION -- each title names one
      # role, so filing a further key produces a DIFFERENT title rather than a
      # second copy of this one. That is exactly the property the old
      # role-generic `agent.turf.solana` lacked, and why it collided.
      #
      # Ids are recorded here as PROVENANCE only -- never passed to `op` -- so a
      # reader whose title read comes back empty can find the item without
      # listing the vault:
      #   solana.turf.admin          2xrfvfho2txchqtem565wmmmfu  BLSBw8fX…
      #   solana.turf.system         hvt5htkgjqsilq5blv3uztqie4  7auwTLSv…  server, MAINNET
      #   solana.turf.system.devnet  luzehmyewswpnbgytyawc25sdy  2eGs8G3w…  server, DEVNET/QA
      #
      # ONLY THE FIRST IS FILED BELOW. The two system items are the SERVER's
      # operational keys, reached through SOLANA_ADMIN_KEY on the dyno; this
      # rehearsal never signs as them, so adding them here would widen what a
      # rehearsal can move for no gain.
      #
      # "turf-admin" (solana.turf.admin, BLSBw8fX) is the turf-5 ADMIN account.
      # It drives the admin HTTP surface and cannot play: its username is the
      # reserved prefix "turf" and it has no on-chain UserAccount, so the
      # program refuses to register it (6020 UsernameReserved). The wallet is
      # unchanged across the re-file -- the item moved, the identity did not.
      #
      # THE DEVNET PAIR NO LONGER RIDES ALONG. The old pinned item also carried
      # devnet-wallet-address / devnet-private-key (2eGs8G3w…), a DIFFERENT
      # wallet, so SECRET_FIELDS and ADDRESS_FIELDS had to avoid those labels or
      # the rehearsal would sign as an account the app has never heard of. That
      # wallet is now its own item (solana.turf.system.devnet) and
      # solana.turf.admin files exactly one pair -- verified 2026-09-15. The
      # label lists still exclude the devnet spellings, which now costs nothing
      # and keeps the guarantee if the pair is ever recombined.
      #
      # "turf" (phantom.turf, 39QTL1dd) is the PLAYER. Its UserAccount already
      # exists, which is the whole reason it works -- ensure_user_account
      # short-circuits on an existing account and never looks at the username.
      ITEMS = {
        "mason"      => Item.new(title: "agent.mason.solana"),
        "mack"       => Item.new(title: "agent.mack.solana"),
        "turf"       => Item.new(title: "phantom.turf"),
        "turf-admin" => Item.new(title: "solana.turf.admin")
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
