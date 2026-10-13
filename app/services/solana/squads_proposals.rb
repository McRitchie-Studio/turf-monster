module Solana
  # The open proposals on this cluster's Squads V4 multisig (the program's
  # upgrade authority and the upgrade reserve), decoded off chain for the
  # signer console: what each one does, its approvals, and, for a program
  # upgrade, whether the buffer it installs is a build this app knows.
  #
  # Agents create these proposals with turf-vault `scripts/squad-upgrade.js`
  # and `scripts/squad-vault-transfer.js` and cast the agent-seat approvals;
  # Mr. McRitchie gives the last approval. This class is what lets him do that
  # from a page that has READ the proposal rather than from a link to bytes.
  #
  # ── LAYOUTS ──────────────────────────────────────────────────────────────
  #
  # Squads V4 accounts are Anchor/Borsh. Verified against
  # @sqds/multisig's generated decoders on live accounts (mainnet #5, #7, #8;
  # devnet #16-#21); the raw bytes are test fixtures.
  #
  #   Proposal          8 disc · multisig 32 · transaction_index u64 ·
  #                     status (u8 tag + i64 timestamp, except tag 4) · bump u8 ·
  #                     approved Vec<Pubkey> · rejected Vec · cancelled Vec
  #   VaultTransaction  8 disc · multisig 32 · creator 32 · index u64 · bump u8 ·
  #                     vault_index u8 · vault_bump u8 · ephemeral bumps Vec<u8> ·
  #                     message { num_signers u8, num_writable_signers u8,
  #                     num_writable_non_signers u8, account_keys Vec<Pubkey>,
  #                     instructions Vec<{program_id_index u8, account_indexes
  #                     Vec<u8>, data Vec<u8>}>, address_table_lookups Vec<…> }
  #
  # Every Vec is a u32 length prefix (Borsh), not the SmallVec of the
  # instruction argument.
  class SquadsProposals
    PROGRAM_ID = Squads::PROGRAM_ID

    PROPOSAL_DISC = [26, 94, 189, 187, 116, 136, 53, 33].pack("C*").b.freeze
    VAULT_TX_DISC = [168, 250, 162, 100, 81, 14, 162, 207].pack("C*").b.freeze
    CONFIG_TX_DISC = [94, 8, 4, 35, 113, 139, 139, 112].pack("C*").b.freeze
    BATCH_DISC = [156, 194, 70, 44, 22, 88, 137, 44].pack("C*").b.freeze
    APPROVE_DISC = [144, 37, 164, 136, 188, 216, 42, 248].pack("C*").b.freeze

    STATUSES = %w[draft active rejected approved executing executed cancelled].freeze
    OPEN = %w[draft active approved].freeze

    BPF_LOADER = "BPFLoaderUpgradeab1e11111111111111111111111".freeze
    SYSTEM_PROGRAM = "11111111111111111111111111111111".freeze
    TOKEN_PROGRAM = "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA".freeze
    ATA_PROGRAM = "ATokenGPvbdGVxr1b2hvZbsiqW5xWH25efTNsLJA8knL".freeze

    BUFFER_HEADER = 37
    UPGRADE_TAG = [3, 0, 0, 0].pack("C*").b.freeze

    # How far back from the newest index to look for open proposals.
    LOOKBACK = 10

    BUILDS_PATH = Rails.root.join("config/turf_vault_builds.yml").freeze

    class DecodeError < StandardError; end

    class Refusal < StandardError
      attr_reader :code

      def initialize(message, code:)
        @code = code
        super(message)
      end
    end

    attr_reader :network, :client

    def initialize(network: Config::NETWORK, client: Config.client,
                   multisig: Config.squads_multisig(network), program_id: Config::PROGRAM_ID)
      @network = network.to_s
      @client = client
      @multisig = multisig.to_s
      @program_id = program_id.to_s
    end

    def multisig_read = @multisig_read ||= Squads.read!(address: @multisig, client: client)

    def vault_pda = multisig_read[:vault_pda]

    def squads_url = "https://app.squads.so/squads/#{vault_pda}/transactions"

    # Every open proposal in the lookback window, newest first. `connected` is
    # the browser's Phantom account, so each row can say whether it can vote.
    def open_proposals(connected: nil)
      ms = multisig_read
      newest = ms[:transaction_index].to_i
      oldest = [newest - LOOKBACK + 1, 1].max

      newest.downto(oldest).filter_map do |index|
        proposal = read_proposal(index)
        next unless proposal && OPEN.include?(proposal[:status])

        row = describe(index, proposal, ms, connected: connected)
        # UPGRADES ONLY. Vault transfers keep the squad-vault-ops link flow and
        # config changes stay in the Squads app; neither is listed here.
        row if row[:summary][:kind] == "upgrade"
      end
    end

    # One proposal, described, or raises Refusal.
    def proposal(index, connected: nil)
      found = read_proposal(index.to_i)
      raise Refusal.new("Proposal ##{index} does not exist on #{network}.", code: "no_proposal") unless found

      describe(index.to_i, found, multisig_read, connected: connected)
    end

    # An UNSIGNED approve transaction for `member` to sign and send in Phantom,
    # after every check this page can make. The member pays the fee: this is
    # a Squads vote, and no server key belongs on it.
    def build_approve(index:, member:)
      row = proposal(index, connected: member)
      unless row[:can_approve]
        raise Refusal.new(row[:approve_blocked] || "This proposal cannot be approved here.", code: "not_approvable")
      end

      tx = Transaction.new
      tx.set_recent_blockhash(client.get_latest_blockhash)
      tx.add_instruction(
        program_id: b(PROGRAM_ID),
        accounts: [
          { pubkey: b(@multisig), is_signer: false, is_writable: false },
          { pubkey: b(member), is_signer: true, is_writable: true },
          { pubkey: b(row[:proposal_pda]), is_signer: false, is_writable: true }
        ],
        # ProposalVoteArgs { memo: None }
        data: APPROVE_DISC + "\x00".b
      )
      { serialized_tx: tx.serialize_partial_base64(additional_signers: [b(member)]),
        index: index.to_i, member: member }
    end

    # ── PDAs ────────────────────────────────────────────────────────────────

    def transaction_pda(index) = pda(["multisig".b, b(@multisig), "transaction".b, [index].pack("Q<")])

    def proposal_pda(index)
      pda(["multisig".b, b(@multisig), "transaction".b, [index].pack("Q<"), "proposal".b])
    end

    # ── decoders (class-level, so tests feed raw fixture bytes) ──────────────

    def self.decode_proposal(data)
      raise DecodeError, "not a Squads proposal" unless data.byteslice(0, 8) == PROPOSAL_DISC

      r = Reader.new(data, 8)
      multisig = r.pubkey
      index = r.u64
      tag = r.u8
      raise DecodeError, "unknown proposal status #{tag}" unless tag < STATUSES.length

      timestamp = tag == 4 ? nil : r.i64
      r.u8 # bump
      { multisig: multisig, transaction_index: index, status: STATUSES[tag], status_at: timestamp,
        approved: r.vec { r.pubkey }, rejected: r.vec { r.pubkey }, cancelled: r.vec { r.pubkey } }
    end

    def self.decode_vault_transaction(data)
      raise DecodeError, "not a Squads vault transaction" unless data.byteslice(0, 8) == VAULT_TX_DISC

      r = Reader.new(data, 8)
      multisig = r.pubkey
      creator = r.pubkey
      index = r.u64
      r.u8 # bump
      vault_index = r.u8
      r.u8 # vault bump
      ephemeral = r.vec { r.u8 }
      header = [r.u8, r.u8, r.u8]
      keys = r.vec { r.pubkey }
      instructions = r.vec do
        { program_id_index: r.u8, account_indexes: r.vec { r.u8 }, data: r.bytes }
      end
      lookups = r.vec { { account_key: r.pubkey, writable: r.vec { r.u8 }, readonly: r.vec { r.u8 } } }

      { multisig: multisig, creator: creator, index: index, vault_index: vault_index,
        ephemeral_signer_bumps: ephemeral, header: header, account_keys: keys,
        instructions: instructions, address_table_lookups: lookups }
    end

    # What a vault transaction does, in a form the page renders.
    def self.summarize(vault_tx)
      unless vault_tx[:address_table_lookups].empty?
        return { kind: "unreadable", text: "Uses address lookup tables; its accounts cannot be read here." }
      end

      keys = vault_tx[:account_keys]
      ixs = vault_tx[:instructions].map do |ix|
        { program: keys.fetch(ix[:program_id_index]), accounts: ix[:account_indexes].map { |i| keys.fetch(i) },
          data: ix[:data] }
      end
      meaningful = ixs.reject { |ix| ix[:program] == ATA_PROGRAM && [0, 1].include?(ix[:data].getbyte(0)) }

      if meaningful.length == 1 && (ix = meaningful.first)
        if ix[:program] == BPF_LOADER && ix[:data] == UPGRADE_TAG && ix[:accounts].length == 7
          return { kind: "upgrade", program_data: ix[:accounts][0], program: ix[:accounts][1],
                   buffer: ix[:accounts][2], spill: ix[:accounts][3], authority: ix[:accounts][6] }
        end
        if ix[:program] == SYSTEM_PROGRAM && ix[:data].bytesize == 12 && ix[:data].unpack1("L<") == 2
          return { kind: "sol_transfer", from: ix[:accounts][0], to: ix[:accounts][1],
                   lamports: ix[:data].byteslice(4, 8).unpack1("Q<") }
        end
        if ix[:program] == TOKEN_PROGRAM && ix[:data].getbyte(0) == 12 && ix[:data].bytesize == 10
          return { kind: "token_transfer", source: ix[:accounts][0], mint: ix[:accounts][1],
                   destination: ix[:accounts][2], authority: ix[:accounts][3],
                   amount: ix[:data].byteslice(1, 8).unpack1("Q<"), decimals: ix[:data].getbyte(9) }
        end
      end

      { kind: "other", programs: ixs.map { |ix| ix[:program] }.uniq, instruction_count: ixs.length }
    end

    # sha256 of a buffer account's program bytes, trailing zeros trimmed.
    def self.buffer_hash(data)
      raise DecodeError, "account is not a loader Buffer" unless data.byteslice(0, 4).unpack1("L<") == 1

      elf = data.byteslice(BUFFER_HEADER..).to_s.sub(/\x00+\z/n, "")
      Digest::SHA256.hexdigest(elf)
    end

    # The buffer's recorded authority, or nil when the buffer is immutable.
    def self.buffer_authority(data)
      return nil unless data.getbyte(4) == 1

      Keypair.encode_base58(data.byteslice(5, 32))
    end

    def self.builds(network, path = BUILDS_PATH)
      Array(YAML.safe_load_file(path)[network.to_s])
    end

    private

    def read_proposal(index)
      raw = account_bytes(proposal_pda(index))
      raw && self.class.decode_proposal(raw)
    end

    def describe(index, proposal, ms, connected:)
      tx_raw = account_bytes(transaction_pda(index))
      kind, summary = classify(tx_raw)
      verification = summary[:kind] == "upgrade" ? verify_upgrade(summary) : nil

      voters = ms[:voting_members]
      approved = proposal[:approved]
      stale = index <= ms[:stale_transaction_index].to_i
      row = {
        index: index,
        proposal_pda: proposal_pda(index),
        transaction_pda: transaction_pda(index),
        status: proposal[:status],
        stale: stale,
        kind: kind,
        summary: summary,
        verification: verification,
        approved: approved,
        threshold: ms[:threshold],
        approvals_needed: [ms[:threshold].to_i - approved.length, 0].max,
        voters: voters,
        squads_url: squads_url,
        connected: connected,
        connected_is_voter: connected.present? && voters.include?(connected),
        connected_approved: connected.present? && approved.include?(connected)
      }
      row[:approve_blocked] = approve_blocked(row)
      row[:can_approve] = row[:approve_blocked].nil?
      row
    end

    def approve_blocked(row)
      return "Connect Phantom to vote." if row[:connected].blank?
      return "The connected account is not a voting member of this Squad." unless row[:connected_is_voter]
      return "The connected account has already approved." if row[:connected_approved]
      return "This proposal is #{row[:status]}, so it takes no more approvals." unless row[:status] == "active"
      return "A config change executed after this proposal, so it can never take another approval." if row[:stale]

      unless row[:summary][:kind] == "upgrade"
        return "Only program upgrades are approved here. Use the Squads app (or the squad-vault-ops link) for this one."
      end

      row[:verification][:ok] ? nil : row[:verification][:reason]
    end

    def classify(raw)
      return ["missing", { kind: "missing" }] if raw.nil?

      case raw.byteslice(0, 8)
      when VAULT_TX_DISC then ["vault", self.class.summarize(self.class.decode_vault_transaction(raw))]
      when CONFIG_TX_DISC then ["config", { kind: "config" }]
      when BATCH_DISC then ["batch", { kind: "batch" }]
      else ["unknown", { kind: "unknown" }]
      end
    rescue DecodeError, IndexError, KeyError => e
      ["unknown", { kind: "unreadable", text: e.message }]
    end

    def verify_upgrade(summary)
      result = { program_matches: summary[:program] == @program_id,
                 authority_is_vault: summary[:authority] == vault_pda,
                 spill_is_vault: summary[:spill] == vault_pda,
                 buffer: summary[:buffer] }
      raw = account_bytes(summary[:buffer])
      if raw.nil?
        return result.merge(ok: false, reason: "The buffer #{summary[:buffer]} no longer exists, so its bytes cannot be checked.")
      end

      result[:buffer_hash] = self.class.buffer_hash(raw)
      result[:buffer_authority] = self.class.buffer_authority(raw)
      build = self.class.builds(network).find { |row| row["sha256"] == result[:buffer_hash] }
      result[:build_version] = build && build["version"]

      reason =
        if !result[:program_matches] then "This upgrade targets #{summary[:program]}, not turf-vault (#{@program_id})."
        elsif !result[:authority_is_vault] then "The upgrade authority it names is not this Squad's vault."
        elsif !result[:spill_is_vault] then "The buffer's rent refund (spill) goes to #{summary[:spill]}, not this Squad's vault."
        elsif result[:buffer_authority] != vault_pda then "The buffer's authority is not this Squad's vault, so someone else could still rewrite it."
        elsif build.nil? then "The buffer's hash #{result[:buffer_hash]} matches no verified build in config/turf_vault_builds.yml for #{network}."
        end
      result.merge(ok: reason.nil?, reason: reason)
    rescue DecodeError => e
      result.merge(ok: false, reason: "The buffer could not be read as a loader buffer: #{e.message}")
    end

    def account_bytes(address)
      raw = client.get_account_info(address.to_s)&.dig("value", "data", 0)
      raw && Base64.decode64(raw)
    end

    def pda(seeds)
      found, _bump = Transaction.find_pda(seeds, b(PROGRAM_ID))
      Keypair.encode_base58(found)
    end

    def b(address) = Keypair.decode_base58(address.to_s)

    # A bounds-checked Borsh cursor.
    class Reader
      def initialize(data, offset)
        @data = data.b
        @at = offset
      end

      def take(n)
        raise DecodeError, "account truncated at byte #{@at}" if @at + n > @data.bytesize

        out = @data.byteslice(@at, n)
        @at += n
        out
      end

      def u8 = take(1).unpack1("C")
      def u32 = take(4).unpack1("L<")
      def u64 = take(8).unpack1("Q<")
      def i64 = take(8).unpack1("q<")
      def pubkey = Keypair.encode_base58(take(32))
      def bytes = take(u32)

      def vec(&block)
        count = u32
        raise DecodeError, "implausible vector length #{count}" if count > 4096

        Array.new(count) { block.call }
      end
    end
  end
end
