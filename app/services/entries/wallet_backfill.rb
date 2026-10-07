module Entries
  # Fills Entry#wallet_address on rows written before the column existed, from
  # the chain, read-only. Nothing is sent on chain.
  #
  # For each entry that stores a ContestEntry PDA and no wallet:
  #
  #   1. Read the account. Its `wallet` field (offset 40) is the wallet that
  #      entered, and is recorded only when [b"entry", sha256(slug), wallet,
  #      entry_num] derives that same PDA and entry_num matches the row's slot.
  #   2. When the account does not exist (closed, or never landed), fall back to
  #      the PDA proof alone: the user's wallet whose seeds derive the stored PDA
  #      (Entry.entering_wallet_for). The seeds bind the wallet, so this is a
  #      proof too.
  #   3. Otherwise leave it nil. Grading refuses a paid entry with no wallet
  #      (Contest#payout_settlements), so an unresolved row is loud, not lost.
  #
  # An unreadable RPC answer skips the row without writing; a re-run picks it up.
  # Idempotent: a row with a wallet is never read again.
  class WalletBackfill
    # turf-vault state.rs ContestEntry, after the 8-byte Anchor discriminator:
    # contest_id [u8;32] @8, wallet Pubkey @40, entry_num u32 @72.
    CONTEST_ID_OFFSET = 8
    WALLET_OFFSET = 40
    ENTRY_NUM_OFFSET = 72
    MIN_BYTES = ENTRY_NUM_OFFSET + 4
    DISCRIMINATOR = Digest::SHA256.digest("account:ContestEntry")[0, 8].freeze

    def self.run(contest: nil, vault: Solana::Vault.new)
      new(contest: contest, vault: vault).run
    end

    def initialize(contest:, vault:)
      @contest = contest
      @vault = vault
    end

    # => { chain: n, derived: n, unresolved: [entry ids], unreadable: [entry ids] }
    def run
      stats = { chain: 0, derived: 0, unresolved: [], unreadable: [] }
      scope.find_each do |entry|
        outcome, wallet = resolve(entry)
        case outcome
        when :chain, :derived
          entry.update_columns(wallet_address: wallet) # a data backfill: no callbacks, no updated_at churn
          stats[outcome] += 1
        when :unreadable then stats[:unreadable] << entry.id
        else stats[:unresolved] << entry.id
        end
      end
      stats
    end

    private

    def scope
      rows = Entry.where(wallet_address: [nil, ""]).where.not(onchain_entry_id: [nil, ""]).includes(:contest, :user)
      @contest ? rows.where(contest_id: @contest.id) : rows
    end

    def resolve(entry)
      info = @vault.client.get_account_info(entry.onchain_entry_id)
      return [:unreadable, nil] unless info.is_a?(Hash) && info.key?("value")
      return derive(entry) if info["value"].nil?

      wallet = wallet_from_account(entry, info["value"])
      wallet ? [:chain, wallet] : [:unresolved, nil]
    rescue Solana::Client::RpcError, JSON::ParserError, Timeout::Error, SocketError, SystemCallError
      [:unreadable, nil]
    end

    def wallet_from_account(entry, value)
      data = Base64.decode64(Array(value["data"]).first.to_s)
      return nil if data.bytesize < MIN_BYTES || data[0, 8] != DISCRIMINATOR
      return nil if data[CONTEST_ID_OFFSET, 32] != Digest::SHA256.digest(entry.contest.slug)

      wallet = Solana::Keypair.encode_base58(data[WALLET_OFFSET, 32])
      num = data[ENTRY_NUM_OFFSET, 4].unpack1("V")
      return nil unless entry.entry_number == num

      derived = Solana::Keypair.encode_base58(@vault.entry_pda(entry.contest.slug, wallet, num).first)
      derived == entry.onchain_entry_id ? wallet : nil
    end

    def derive(entry)
      wallet = Entry.entering_wallet_for(
        contest_slug: entry.contest.slug, entry_pda: entry.onchain_entry_id, entry_number: entry.entry_number,
        candidates: [entry.user&.web2_solana_address, entry.user&.web3_solana_address], vault: @vault
      )
      wallet ? [:derived, wallet] : [:unresolved, nil]
    end
  end
end
