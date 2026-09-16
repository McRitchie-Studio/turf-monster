module Solana
  # The SQUADS V4 MULTISIG — the authority that can REDEPLOY the program.
  #
  # ── IT IS NOT THE VAULT SIGNER SET, AND THE PAGE MUST NOT SAY "MULTISIG" ──
  #
  # Three separate authorities meet in this app and conflating them is the
  # recurring defect (see the three-way note on `Solana::Config::MULTISIG_SIGNERS`):
  #
  #   1. `VaultState.signers`  — signs vault ACTIONS (settle, sweep, pause,
  #      update_signers). Lives inside turf-vault. Changed by `update_signers`.
  #   2. THIS — the Squads V4 multisig holding the BPFLoaderUpgradeable upgrade
  #      authority for PROGRAM_ID. Lives in the Squads program. Changed through
  #      Squads' own config transactions and its own web UI.
  #   3. `KeyStore::ITEMS["turf-admin"]` — a 1Password FILING. Not on chain at
  #      all, and never evidence about either of the above.
  #
  # So never write "the multisig" unqualified anywhere this class is rendered.
  # Say "vault signer set" or "Squads upgrade multisig".
  #
  # ── WHY THIS READS THE CHAIN RATHER THAN A CONSTANT ───────────────────────
  #
  # Because the constants were WRONG when this was written, in two different
  # places, on the same day. `Solana::Config::MULTISIG_SIGNERS`' own comment
  # said the Squad was "FOUR at threshold 3"; `docs/SOLANA.md` said five members
  # at three; the admin hub tile said "2-of-3". Measured 2026-09-15, BOTH
  # clusters read **threshold 3 of 5**, every member at mask 7. A number written
  # down is a claim; this class is a measurement.
  #
  # ── THE VAULT PDA IS DERIVED, NEVER COMPARED AGAINST THE MULTISIG ─────────
  #
  # The address that actually holds upgrade authority is a PDA *owned by* the
  # multisig, not the multisig account itself — `[b"multisig", multisig, b"vault",
  # index]` under the Squads program. Comparing `solana program show`'s Authority
  # line against the MULTISIG address is a mistake this ecosystem has made twice,
  # and it always reads as "the authority is wrong" when nothing is wrong.
  # `vault_pda` derives it so the page can prove the match instead of asserting it.
  #
  # Layout below hand-decoded against devnet `7nRuVw3V…` on 2026-09-15 and
  # cross-checked field-for-field against `@sqds/multisig`'s own
  # `Multisig.fromAccountAddress` — same threshold, same five members, same masks.
  class Squads
    # Squads V4 program. The vault PDA seeds are derived under THIS id, never
    # under turf-vault's.
    PROGRAM_ID = "SQDS4ep65T869zMMBKyuUq6aD6EgTu8psMjkvj52pCf".freeze

    # Permission bits on `Member.permissions.mask`.
    INITIATE = 1
    VOTE     = 2
    EXECUTE  = 4

    # Fixed prefix ahead of `members`: 8 discriminator + 32 create_key +
    # 32 config_authority + 2 threshold (u16 LE) + 4 time_lock (u32 LE) +
    # 8 transaction_index + 8 stale_transaction_index. `rent_collector` is an
    # Option<Pubkey> whose tag byte follows, then `bump`, then the members vec.
    DISCRIMINATOR_LEN   = 8
    CREATE_KEY_OFFSET   = DISCRIMINATOR_LEN
    CONFIG_AUTH_OFFSET  = CREATE_KEY_OFFSET + 32
    THRESHOLD_OFFSET    = CONFIG_AUTH_OFFSET + 32
    TIME_LOCK_OFFSET    = THRESHOLD_OFFSET + 2
    TX_INDEX_OFFSET     = TIME_LOCK_OFFSET + 4
    RENT_COLLECTOR_TAG_OFFSET = TX_INDEX_OFFSET + 16 # transaction_index + stale
    MEMBER_LEN = 33 # 32 pubkey + 1 permission mask

    # Raised only by `read!`. `read` swallows it — an authority PAGE must still
    # render when one of three chain reads flakes, and a blank panel that says
    # "could not read" is worth more than a 500.
    class ReadError < StandardError; end

    class << self
      # Decode the Squads multisig at `address`, or nil when it cannot be read.
      #
      # NEVER RAISES. The overview renders three authorities side by side and a
      # transient RPC failure on one of them must not take the other two down
      # with it — least of all on the page an operator opens during an incident.
      def read(address: Config.squads_multisig, client: Config.client)
        read!(address: address, client: client)
      rescue StandardError => e
        Rails.logger.warn("[solana] squads read failed: #{Config.redact_message(e.message)}")
        nil
      end

      # Same read, raising. For tests and for callers that want the reason.
      def read!(address: Config.squads_multisig, client: Config.client)
        raise ReadError, "no Squads multisig configured for this cluster" if address.blank?

        info = client.get_account_info(address.to_s)
        raw  = info&.dig("value", "data", 0)
        raise ReadError, "Squads multisig #{address} not found on this cluster" if raw.nil?

        owner = info.dig("value", "owner")
        if owner.present? && owner != PROGRAM_ID
          raise ReadError,
                "account #{address} is owned by #{owner}, not the Squads V4 program (#{PROGRAM_ID}) — " \
                "this is not a Squads multisig."
        end

        decode(Base64.decode64(raw)).merge(
          address: address.to_s,
          vault_pda: vault_pda(address)
        )
      end

      # Decode the raw account bytes. Split out from the RPC so the layout can
      # be tested against a recorded fixture with no network.
      def decode(data)
        need!(data, RENT_COLLECTOR_TAG_OFFSET + 1, "header")

        threshold  = data.byteslice(THRESHOLD_OFFSET, 2).unpack1("S<")
        time_lock  = data.byteslice(TIME_LOCK_OFFSET, 4).unpack1("L<")
        create_key = Keypair.encode_base58(data.byteslice(CREATE_KEY_OFFSET, 32))
        config_authority = Keypair.encode_base58(data.byteslice(CONFIG_AUTH_OFFSET, 32))

        # `rent_collector: Option<Pubkey>` — one tag byte, then 32 more when Some.
        # Getting this wrong shifts EVERY member key by 32 bytes and the decode
        # still "succeeds", returning plausible-looking garbage. That is why the
        # tag is read rather than assumed, and why the member count is bounds-
        # checked against the real account length below.
        tag    = data.getbyte(RENT_COLLECTOR_TAG_OFFSET)
        raise ReadError, "malformed rent_collector option tag #{tag.inspect}" unless [0, 1].include?(tag)

        cursor = RENT_COLLECTOR_TAG_OFFSET + 1
        rent_collector = nil
        if tag == 1
          need!(data, cursor + 32, "rent_collector")
          rent_collector = Keypair.encode_base58(data.byteslice(cursor, 32))
          cursor += 32
        end

        need!(data, cursor + 1 + 4, "members header")
        bump   = data.getbyte(cursor)
        cursor += 1
        count  = data.byteslice(cursor, 4).unpack1("L<")
        cursor += 4

        need!(data, cursor + count * MEMBER_LEN, "members (#{count})")

        members = Array.new(count) do |i|
          off  = cursor + i * MEMBER_LEN
          mask = data.getbyte(off + 32)
          {
            address:      Keypair.encode_base58(data.byteslice(off, 32)),
            mask:         mask,
            can_initiate: mask.anybits?(INITIATE),
            can_vote:     mask.anybits?(VOTE),
            can_execute:  mask.anybits?(EXECUTE)
          }
        end

        {
          create_key: create_key,
          config_authority: config_authority,
          threshold: threshold,
          time_lock: time_lock,
          bump: bump,
          rent_collector: rent_collector,
          members: members,
          # A member can only help REACH the threshold if it may vote. A
          # seats-count that ignored the mask would overstate what a stolen key
          # buys, which is the number this page exists to state correctly.
          voting_members: members.select { |m| m[:can_vote] }.map { |m| m[:address] }
        }
      end

      # `[b"multisig", <multisig>, b"vault", <index u8>]` under the SQUADS
      # program. Index 0 is the default vault and the one that holds turf-vault's
      # upgrade authority on both clusters.
      def vault_pda(multisig_address, index: 0)
        pda, _bump = Transaction.find_pda(
          [
            "multisig".b,
            Keypair.decode_base58(multisig_address.to_s),
            "vault".b,
            [index].pack("C")
          ],
          Keypair.decode_base58(PROGRAM_ID)
        )
        Keypair.encode_base58(pda)
      end

      private

      def need!(data, length, what)
        return if data.bytesize >= length

        raise ReadError,
              "Squads account truncated: need #{length} bytes for #{what}, have #{data.bytesize}"
      end
    end
  end
end
