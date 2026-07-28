require "digest"

module Solana
  # Solana::Vault — Rails-side service layer for the turf-vault Anchor
  # program (v0.16).
  #
  # v0.16 architecture (server-signed self-custody):
  #   - USDC lives in each user's own ATA (not a vault PDA).
  #   - Contest entry = SPL transfer from user ATA → per-currency op_rev ATA.
  #   - Contest payouts = SPL transfer from per-contest prize_pool PDA → winner ATA.
  #   - No deposit / withdraw / balance / daily cap instructions on-chain.
  #     Managed-wallet "withdrawals" are handled off-chain (operator flow —
  #     see PayoutRequest model, coming in Phase 2).
  #
  # Instruction surface (16 + pause/unpause = 18):
  #   initialize, register_currency, deactivate_currency,
  #   create_user_account, set_username,
  #   create_season,
  #   create_contest, set_contest_lock_time, set_contest_conclusion_time,
  #   enter_contest, enter_contest_with_token,
  #   settle_contest, cancel_contest, close_contest,
  #   mint_entry_token, sweep_operator_revenue,
  #   pause, unpause.
  class Vault
    attr_reader :client

    # Default compute-unit limit for settle_contest. v0.16 settle does an
    # SPL CPI per winner; the spec recommends 400_000 for headroom up to ~50
    # winners (spec §3.12, §10.1, §11 Q7).
    SETTLE_COMPUTE_UNIT_LIMIT = 400_000

    # Single source of truth for the admin vault-state cache key. Read
    # cache-first on the navbar preload path (ApplicationController) and
    # fetch-with-race_condition_ttl in .cached_vault_state, so read-key and
    # write-key can never drift.
    VAULT_STATE_CACHE_KEY = "solana:vault_state"

    # ComputeBudget program id (deterministic).
    COMPUTE_BUDGET_PROGRAM_ID = Keypair.decode_base58("ComputeBudget111111111111111111111111111111")

    # Lighthouse — Phantom's transaction-protection program. On MAINNET (not
    # devnet, which is why staging never sees it) Phantom may INJECT Lighthouse
    # assertion instructions into the tx at signing time. Lighthouse
    # instructions are pure post-state assertions: they can only make the tx
    # FAIL, never move funds or delegate authority, so allowing them preserves
    # the C1 cosign-safety model. Without this every protected Phantom signer
    # is cosign-rejected with "disallowed_program" (hit in prod 2026-06-11).
    LIGHTHOUSE_PROGRAM_ID = Keypair.decode_base58("L2TExMFKdjpN9kozasaurPirfHy9P8sbXoAN1qA3S95")

    # Priority fee for the Phantom-signed partial TXs (create_contest,
    # enter_contest, set_contest_lock_time/conclusion_time, cancel_contest —
    # everything that routes through `build_partial_signed`).
    #
    # WHY: these TXs carried NO priority fee. On an empty devnet a fee-less TX
    # lands fine; on mainnet-beta under load the leader deprioritizes/drops
    # fee-less TXs, which is exactly the devnet-works/mainnet-drops trap behind
    # the two create_contest TXs (22opEv2o…, 4CsVqf…) that never landed
    # (2026-06-02). Adding a ComputeBudget setComputeUnitPrice (+ a sized
    # setComputeUnitLimit) makes the leader pick the TX up.
    #
    # Value math (defaults): 50_000 µlamports/CU × 200_000 CU limit
    #   = 1.0e10 µlamports = 10_000 lamports = 0.00001 SOL per TX.
    # Negligible cost, comfortably above the fee-less floor. Both ENV-overridable
    # so we can crank them for the first mainnet attempt without a redeploy.
    PARTIAL_TX_PRIORITY_FEE_MICROLAMPORTS =
      ENV.fetch("SOLANA_PRIORITY_FEE_MICROLAMPORTS", "50000").to_i

    # CU cap for the partial-signed instructions. create_contest does two PDA
    # inits (contest + prize_pool ATA) plus one SPL transfer — well under
    # 200_000. A generous-but-bounded limit keeps the priority-fee math
    # predictable (fee = price × limit) and avoids over-reserving CUs.
    PARTIAL_TX_COMPUTE_UNIT_LIMIT =
      ENV.fetch("SOLANA_PARTIAL_TX_COMPUTE_UNIT_LIMIT", "200000").to_i

    # Sentinel currency_idx for token-funded entries (spec §3.11 / §11 Q2).
    TOKEN_FUNDED_CURRENCY_IDX = 255

    # Solana's `Pubkey::default()` (32 zero bytes) base58-encoded.
    ZERO_PUBKEY_B58 = "11111111111111111111111111111111".freeze

    # Quest seed-grant kinds — mirror turf-vault `seed_grant_kind` (grant_seeds).
    # Part of the [b"seed_grant", wallet, kind, invitee] guard-PDA seed.
    # CHAT_MESSAGE = 3 added in v0.23 (send first contest-chat message quest).
    SEED_GRANT_KIND = { username: 0, newsletter: 1, invite: 2, chat: 3 }.freeze

    def initialize(client: Solana::Client.new)
      @client = client
      @program_id = Keypair.decode_base58(Config::PROGRAM_ID)
    end

    # Raised when the configured PROGRAM_ID doesn't exist on the configured RPC.
    # Indicates one of:
    #   - Stale Sidekiq process: its env was loaded before a devnet redeploy
    #     swapped PROGRAM_ID. Killing + restarting Sidekiq picks up the fresh
    #     env. Both bugs we hit on 2026-05-27 and 2026-05-28 took this shape.
    #   - Cluster mismatch: SOLANA_NETWORK=devnet but SOLANA_RPC_URL points at
    #     a mainnet endpoint (or vice versa).
    #   - Wrong PROGRAM_ID env var entirely.
    class StaleEnvError < StandardError; end

    # Defensive guard for callers that are about to mutate on-chain state
    # (mint, enter, settle, …). One getAccountInfo call against PROGRAM_ID.
    # Result cached 5 minutes so we don't pay the extra RPC on every job;
    # negative results raise immediately and are NOT cached, so a fix to
    # env / config takes effect on the next retry.
    PROGRAM_ID_LIVE_CACHE_KEY = "solana/program_id_live/v1".freeze

    def self.ensure_program_id_live!(client: nil)
      cache_key = "#{PROGRAM_ID_LIVE_CACHE_KEY}/#{Config::PROGRAM_ID}/#{Config::RPC_URL[0, 64]}"
      return if Rails.cache.read(cache_key)

      client ||= Solana::Client.new
      info = client.get_account_info(Config::PROGRAM_ID)
      live = info&.dig("value")
      if live.nil?
        raise StaleEnvError,
              "Solana PROGRAM_ID=#{Config::PROGRAM_ID} does not exist on RPC " \
              "#{Config::RPC_URL.to_s[0, 60]}#{'…' if Config::RPC_URL.to_s.length > 60}. " \
              "Sidekiq may have a stale env from before a devnet redeploy — " \
              "restart it. (Set SKIP_PROGRAM_ID_LIVE_CHECK=true to bypass.)"
      end
      Rails.cache.write(cache_key, true, expires_in: 5.minutes)
    rescue StaleEnvError
      raise
    rescue => e
      # Transient RPC errors (429, network blip) shouldn't fail the job —
      # let the actual mint surface its own error. We only raise on the
      # definitive "account doesn't exist" response.
      Rails.logger.warn "[solana] ensure_program_id_live! RPC error (skipping check): #{e.class}: #{e.message[0,120]}"
    end

    # --- PDA helpers ---

    def vault_state_pda
      Transaction.find_pda([b("vault")], @program_id)
    end

    def user_account_pda(wallet_address)
      wallet_bytes = Keypair.decode_base58(wallet_address)
      Transaction.find_pda([b("user"), wallet_bytes], @program_id)
    end

    def contest_pda(contest_slug)
      contest_id = Digest::SHA256.digest(contest_slug)
      Transaction.find_pda([b("contest"), contest_id], @program_id)
    end

    def entry_pda(contest_slug, wallet_address, entry_num)
      contest_id = Digest::SHA256.digest(contest_slug)
      wallet_bytes = Keypair.decode_base58(wallet_address)
      entry_num_bytes = [entry_num].pack("V") # u32 LE
      Transaction.find_pda([b("entry"), contest_id, wallet_bytes, entry_num_bytes], @program_id)
    end

    # Lowest entry slot in 0...max whose on-chain Entry PDA does NOT already
    # exist for (contest, wallet), skipping any indices in `skip`. Returns nil
    # if every slot is taken.
    #
    # WHY probe the chain instead of counting DB rows: the Entry PDA is seeded
    # on the entry index, and on-chain Entry accounts OUTLIVE their DB rows — a
    # contest Reset (Contest#reset!) destroys the DB entries but never closes
    # their on-chain accounts. Deriving the next index from a live DB count then
    # reuses a slot whose PDA is still allocated, and EnterContest's System
    # `Allocate` fails with "account ... already in use" (custom program error
    # 0x0) at pre-flight. The chain is the only source of truth for which slots
    # are free. See Entry#assign_onchain_entry_number!.
    def next_free_entry_index(contest_slug, wallet_address, max:, skip: [])
      skip = Array(skip).map(&:to_i)
      (0...max).each do |n|
        next if skip.include?(n)
        pda = Keypair.encode_base58(entry_pda(contest_slug, wallet_address, n).first)
        info = @client.get_account_info(pda)
        return n unless info && info["value"]
      end
      nil
    end

    # Build the source_ref for an operator-initiated entry-token mint (the
    # /admin/free_entries "Mint N" / "Mint All" buttons). It MUST be globally
    # unique per mint — the on-chain PDA is sha256(source_ref), so a repeat
    # collides on init — AND fit the [u8;64] limit padded_source_ref enforces.
    # Keyed on user.id + a random nonce, NOT the ~44-char wallet address:
    # "operator:" + a base58 address + a 32-char nonce ran ~86 bytes, so
    # padded_source_ref raised and ZERO owed free entries minted in prod (v119
    # caution). user.id is the trace; the nonce alone guarantees uniqueness;
    # even a max bigint id keeps this ~61 bytes. The ref is opaque (only hashed
    # + logged, never parsed back), so dropping the address loses nothing.
    def self.operator_source_ref(user)
      "operator:#{user.id}:#{SecureRandom.hex(16)}"
    end

    # The EntryTokenAccount PDA is seeded on sha256 of `source_ref` zero-padded
    # to [u8;64] (turf-vault v0.19, audit #9 — replaces the old wallet+sequence
    # seed). The mint instruction's `source_ref_hash` arg AND this derivation
    # MUST hash the SAME 64-byte buffer the program hashes, or Ruby and the
    # program disagree on the address. Both go through these two helpers so they
    # can't drift — see test/services/solana/entry_token_pda_test.rb.
    def padded_source_ref(source_ref)
      bytes = source_ref.to_s.b.bytes
      # The on-chain source_ref is [u8;64]. Silently truncating a longer ref
      # drops its tail — which is exactly how a multi-token purchase's
      # "...:#{i}" suffix got cut off so every token shared ONE PDA and
      # collided on init (custom program error 0x0). Fail loud instead: callers
      # MUST keep source_refs <= 64 bytes (and globally unique per token).
      if bytes.length > 64
        raise ArgumentError, "source_ref exceeds the on-chain [u8;64] limit " \
          "(#{bytes.length} bytes): #{source_ref.inspect}"
      end
      bytes += [0] * (64 - bytes.length)
      bytes.pack("C*")
    end

    def entry_token_seed_hash(source_ref)
      Digest::SHA256.digest(padded_source_ref(source_ref))
    end

    def entry_token_pda(source_ref)
      Transaction.find_pda([b("entry_token"), entry_token_seed_hash(source_ref)], @program_id)
    end

    def season_pda(season_id)
      id_bytes = [season_id].pack("V") # u32 LE
      Transaction.find_pda([b("season"), id_bytes], @program_id)
    end

    # Per-contest USDC prize-pool PDA (v0.16). Holds the prize_pool USDC.
    # Authority = vault_state PDA. Seeds: [b"prize_pool", contest_id].
    def prize_pool_pda(contest_slug)
      contest_id = Digest::SHA256.digest(contest_slug)
      Transaction.find_pda([b("prize_pool"), contest_id], @program_id)
    end

    # Per-currency operator-revenue ATA (v0.16). Authority = vault_state PDA.
    # Seeds: [b"op_rev", mint]. Accepts a base58 string or 32-byte buffer.
    def op_rev_ata_pda(mint)
      mint_bytes = mint.is_a?(String) ? Keypair.decode_base58(mint) : mint
      Transaction.find_pda([b("op_rev"), mint_bytes], @program_id)
    end

    # --- ATA helpers ---

    def admin_usdc_ata
      admin = Keypair.admin
      Solana::SplToken.find_associated_token_address(admin.public_key_bytes, Config::USDC_MINT)
    end

    # Ensure an ATA exists for wallet + mint. Creates it if missing.
    # Returns { ata: base58, created: bool, signature: string|nil }
    def ensure_ata(wallet_address, mint:)
      ata_bytes, _ = Solana::SplToken.find_associated_token_address(wallet_address, mint)
      ata_base58 = Keypair.encode_base58(ata_bytes)

      info = client.get_account_info(ata_base58)
      if info&.dig("value")
        return { ata: ata_base58, created: false, signature: nil }
      end

      admin = Keypair.admin
      create_ix = Solana::SplToken.create_associated_token_account_instruction(
        payer: admin.public_key_bytes,
        wallet: wallet_address,
        mint: mint
      )

      tx = build_tx(admin)
      tx.add_instruction(**create_ix)
      signature = client.send_and_confirm(tx.serialize_base64)

      { ata: ata_base58, created: true, signature: signature }
    rescue Solana::Client::RpcError => e
      raise unless e.message.include?("IllegalOwner")
      info = client.get_account_info(ata_base58)
      raise unless info&.dig("value")
      { ata: ata_base58, created: false, signature: nil }
    end

    # Mint SPL tokens (admin must be mint authority — devnet test mints).
    def mint_spl(amount_lamports, mint:, to: nil)
      admin = Keypair.admin

      if to
        dest_bytes, _ = Solana::SplToken.find_associated_token_address(to, mint)
      else
        dest_bytes, _ = admin_usdc_ata
      end

      mint_ix = Solana::SplToken.mint_to_instruction(
        mint: mint,
        destination: dest_bytes,
        authority: admin.public_key_bytes,
        amount: amount_lamports
      )

      tx = build_tx(admin)
      tx.add_instruction(**mint_ix)
      signature = client.send_and_confirm(tx.serialize_base64)

      { signature: signature, amount: amount_lamports, destination: Keypair.encode_base58(dest_bytes) }
    end

    # Transfer SPL tokens from admin's ATA to a recipient wallet's ATA.
    # Ensures recipient ATA exists first.
    def transfer_spl(to_wallet, amount_lamports, mint:)
      admin = Keypair.admin

      ensure_ata(to_wallet, mint: mint)

      from_bytes, _ = Solana::SplToken.find_associated_token_address(admin.public_key_bytes, mint)
      to_bytes, _ = Solana::SplToken.find_associated_token_address(to_wallet, mint)

      transfer_ix = Solana::SplToken.transfer_instruction(
        from: from_bytes, to: to_bytes,
        authority: admin.public_key_bytes, amount: amount_lamports
      )

      tx = build_tx(admin)
      tx.add_instruction(**transfer_ix)
      signature = client.send_and_confirm(tx.serialize_base64)

      { signature: signature, amount: amount_lamports, destination: Keypair.encode_base58(to_bytes) }
    end

    # --- Offramp send (Coinbase CDP cash-out — docs/CDP_RAMP_INTEGRATION.md §10) ---

    # Build + SIGN (server-side, both signers) the USDC SPL transfer that
    # fulfills a managed-wallet offramp: user's USDC ATA → the RESOLVED
    # Coinbase destination token account (Cdp::OfframpDestination — never the
    # raw to_address). Authority = the user's managed keypair; admin = fee
    # payer (managed wallets hold no SOL). Carries the same ComputeBudget
    # priority-fee pair as the Phantom partial TXs (the mainnet tx-landing fix).
    #
    # DOES NOT BROADCAST. Returns { wire_base64:, signature: } so the caller
    # can durably persist the tx signature BEFORE attempting the broadcast —
    # the verify-before-retry anchor (Cdp::OfframpSendJob: on any timeout or
    # ambiguous RPC result, check the signature on-chain; never blind-resend).
    def build_user_usdc_transfer(user_keypair:, destination_token_account:, amount_lamports:)
      raise ArgumentError, "user_keypair required" unless user_keypair
      raise ArgumentError, "amount must be positive" unless amount_lamports.to_i.positive?

      admin = Keypair.admin
      from_ata, _ = Solana::SplToken.find_associated_token_address(
        user_keypair.public_key_bytes, Config::USDC_MINT
      )

      tx = build_tx(admin)
      tx.add_signer(user_keypair)
      tx.add_instruction(**compute_unit_price_ix(PARTIAL_TX_PRIORITY_FEE_MICROLAMPORTS))
      tx.add_instruction(**compute_unit_limit_ix(PARTIAL_TX_COMPUTE_UNIT_LIMIT))
      tx.add_instruction(**Solana::SplToken.transfer_instruction(
        from: from_ata,
        to: destination_token_account,
        authority: user_keypair.public_key_bytes,
        amount: amount_lamports.to_i
      ))

      wire = tx.serialize
      { wire_base64: Base64.strict_encode64(wire), signature: extract_tx_signature(wire) }
    end

    # Phantom flavor for the offramp send: a fully-UNSIGNED single-signer tx —
    # the user's wallet is BOTH fee payer and transfer authority. Phantom signs
    # and the client broadcasts (mirroring the lock_contest sign flow), then
    # POSTs the signature back to /cdp/offramp/sent for verified recording.
    def build_user_usdc_transfer_unsigned(wallet_address:, destination_token_account:, amount_lamports:)
      raise ArgumentError, "amount must be positive" unless amount_lamports.to_i.positive?

      wallet_bytes = Keypair.decode_base58(wallet_address)
      from_ata, _ = Solana::SplToken.find_associated_token_address(wallet_address, Config::USDC_MINT)

      tx = build_tx_unsigned
      tx.add_instruction(**compute_unit_price_ix(PARTIAL_TX_PRIORITY_FEE_MICROLAMPORTS))
      tx.add_instruction(**compute_unit_limit_ix(PARTIAL_TX_COMPUTE_UNIT_LIMIT))
      tx.add_instruction(**Solana::SplToken.transfer_instruction(
        from: from_ata,
        to: destination_token_account,
        authority: wallet_bytes,
        amount: amount_lamports.to_i
      ))

      { serialized_tx: tx.serialize_partial_base64(additional_signers: [wallet_bytes]) }
    end

    # Fund a user's wallet ATA with USDC.
    # Devnet: mints new tokens (admin holds mint authority on test mints).
    # Mainnet: transfers from admin's treasury ATA.
    #
    # v0.16: there is no vault deposit step after this — USDC lives in the
    # user's ATA, period. Stripe/MoonPay deposit jobs call this and stop.
    def fund_user(wallet_address, amount_lamports, mint: :usdc)
      mint_key = mint == :usdc ? Config::USDC_MINT : Config::USDT_MINT
      ensure_ata(wallet_address, mint: mint_key)

      if Config.devnet?
        mint_spl(amount_lamports, mint: mint_key, to: wallet_address)
      else
        transfer_spl(wallet_address, amount_lamports, mint: mint_key)
      end
    end

    # --- Vault initialization (one-time per program deploy) ---

    # Build a partially-signed `initialize` transaction for Phantom to cosign.
    #
    # v0.16 signature: signers[3] + threshold + treasury_authority (Squads vault PDA).
    # Initial accepted_currencies are wired up server-side: slot 0 = USDC (payout),
    # slot 1 = USDT. Both op_rev ATAs are init'd in the same TX.
    #
    # Mainnet `initialize` requires admin == INIT_AUTHORITY (a Phantom key
    # the server doesn't hold), so this builder puts `creator_pubkey` in the
    # admin slot and the bot only fee-pays.
    def build_initialize_vault(creator_pubkey:, signers:, threshold:, treasury_authority:)
      creator_bytes = Keypair.decode_base58(creator_pubkey)
      vault_pda, _ = vault_state_pda
      usdc_mint = Keypair.decode_base58(Config::USDC_MINT)
      usdt_mint = Keypair.decode_base58(Config::USDT_MINT)
      treasury_authority_bytes = Keypair.decode_base58(treasury_authority)

      payout_op_rev, _ = op_rev_ata_pda(Config::USDC_MINT)
      second_op_rev,  _ = op_rev_ata_pda(Config::USDT_MINT)

      data = Transaction.anchor_discriminator("initialize") +
             signers.map { |s| Borsh.encode_pubkey(Keypair.decode_base58(s)) }.join +
             Borsh.encode_u8(threshold) +
             Borsh.encode_pubkey(treasury_authority_bytes)

      serialized = build_partial_signed(
        accounts: [
          { pubkey: creator_bytes,         is_signer: true,  is_writable: true  }, # admin (== INIT_AUTHORITY on mainnet)
          { pubkey: vault_pda,             is_signer: false, is_writable: true  },
          { pubkey: usdc_mint,             is_signer: false, is_writable: false }, # payout_mint
          { pubkey: usdt_mint,             is_signer: false, is_writable: false }, # second_currency_mint
          { pubkey: payout_op_rev,         is_signer: false, is_writable: true  }, # payout_op_rev_ata (init)
          { pubkey: second_op_rev,         is_signer: false, is_writable: true  }, # second_op_rev_ata (init)
          { pubkey: Transaction::TOKEN_PROGRAM_ID,  is_signer: false, is_writable: false },
          { pubkey: Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false },
          { pubkey: Transaction::SYSVAR_RENT_PUBKEY, is_signer: false, is_writable: false }
        ],
        data: data,
        additional_signers: [creator_bytes]
      )
      { serialized_tx: serialized, vault_pda: Keypair.encode_base58(vault_pda) }
    end

    # Server-signed `initialize` — devnet / dev builds only.
    # Used by `bin/rails solana:init_vault INIT=true`. Mainnet always uses
    # the Phantom co-sign path (build_initialize_vault).
    def initialize_vault(signers:, threshold:, treasury_authority:)
      admin = Keypair.admin
      vault_pda, _ = vault_state_pda
      usdc_mint = Keypair.decode_base58(Config::USDC_MINT)
      usdt_mint = Keypair.decode_base58(Config::USDT_MINT)
      treasury_authority_bytes = Keypair.decode_base58(treasury_authority)

      payout_op_rev, _ = op_rev_ata_pda(Config::USDC_MINT)
      second_op_rev,  _ = op_rev_ata_pda(Config::USDT_MINT)

      data = Transaction.anchor_discriminator("initialize") +
             signers.map { |s| Borsh.encode_pubkey(Keypair.decode_base58(s)) }.join +
             Borsh.encode_u8(threshold) +
             Borsh.encode_pubkey(treasury_authority_bytes)

      tx = build_tx(admin)
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: admin.public_key_bytes, is_signer: true,  is_writable: true  },
          { pubkey: vault_pda,              is_signer: false, is_writable: true  },
          { pubkey: usdc_mint,              is_signer: false, is_writable: false },
          { pubkey: usdt_mint,              is_signer: false, is_writable: false },
          { pubkey: payout_op_rev,          is_signer: false, is_writable: true  },
          { pubkey: second_op_rev,          is_signer: false, is_writable: true  },
          { pubkey: Transaction::TOKEN_PROGRAM_ID,   is_signer: false, is_writable: false },
          { pubkey: Transaction::SYSTEM_PROGRAM_ID,  is_signer: false, is_writable: false },
          { pubkey: Transaction::SYSVAR_RENT_PUBKEY, is_signer: false, is_writable: false }
        ],
        data: data
      )

      signature = client.send_and_confirm(tx.serialize_base64)
      { signature: signature, vault_pda: Keypair.encode_base58(vault_pda) }
    end

    # --- VaultState reads (zero-copy / bytemuck layout) ---
    #
    # v0.16 VaultState is #[account(zero_copy(unsafe))] + #[repr(C)]:
    #   offset  field                    size
    #      0    discriminator              8
    #      8    signers[3]                96
    #    104    threshold                  1
    #    105    bump                       1
    #    106    paused (u8 0/1)            1
    #    107    payout_mint               32
    #    139    treasury_authority        32
    #    171    accepted_currencies[16] 1280  (each slot = 80 bytes)
    #   1451    _reserved                 64
    #   1515    end
    #
    # Each AcceptedCurrency slot (80 bytes):
    #     0    mint                       32
    #    32    op_rev_ata                 32
    #    64    kind                        1
    #    65    active (u8 0/1)             1
    #    66    _pad                       14
    #
    # Returns nil if the account doesn't exist (vault uninitialized).
    #
    # Compatibility: callers (admin views, navbar) still read
    # `:usdc_mint` / `:usdt_mint`. Those are sourced from slots 0/1 of the
    # accepted_currencies array.
    def read_vault_state(commitment: "confirmed")
      pda, _ = vault_state_pda
      info = client.get_account_info(Keypair.encode_base58(pda), commitment: commitment)
      return nil unless info&.dig("value")

      data = Base64.decode64(info["value"]["data"][0])

      signers = 3.times.map do |i|
        Keypair.encode_base58(data.byteslice(8 + i * 32, 32))
      end
      threshold = data.byteslice(104, 1).unpack1("C")
      bump      = data.byteslice(105, 1).unpack1("C")
      paused    = data.byteslice(106, 1).unpack1("C") == 1
      payout_mint        = Keypair.encode_base58(data.byteslice(107, 32))
      treasury_authority = Keypair.encode_base58(data.byteslice(139, 32))

      currencies = 16.times.map do |i|
        off = 171 + i * 80
        {
          slot:       i,
          mint:       Keypair.encode_base58(data.byteslice(off, 32)),
          op_rev_ata: Keypair.encode_base58(data.byteslice(off + 32, 32)),
          kind:       data.byteslice(off + 64, 1).unpack1("C"),
          active:     data.byteslice(off + 65, 1).unpack1("C") == 1
        }
      end
      # Pubkey::default().to_base58 == "11111111111111111111111111111111".
      registered = currencies.select { |c| c[:mint] != ZERO_PUBKEY_B58 }

      # Back-compat keys for admin views written against the v0.15.1 shape.
      slot0 = registered.find { |c| c[:slot] == 0 }
      slot1 = registered.find { |c| c[:slot] == 1 }

      {
        pda:                 Keypair.encode_base58(pda),
        signers:             signers,
        threshold:           threshold,
        bump:                bump,
        paused:              paused,
        payout_mint:         payout_mint,
        treasury_authority:  treasury_authority,
        accepted_currencies: currencies,
        registered_currencies: registered,
        # Back-compat: admin views read these directly.
        usdc_mint:           slot0 ? slot0[:mint] : nil,
        usdt_mint:           slot1 ? slot1[:mint] : nil,
        # v0.16 removed pooled USDC/USDT vault PDAs; surface op_rev as the
        # closest analog so existing views don't 500 on a nil read.
        vault_usdc:          slot0 ? slot0[:op_rev_ata] : nil,
        vault_usdt:          slot1 ? slot1[:op_rev_ata] : nil
      }
    end

    # Per-request memoized VaultState read. See ApplicationController's
    # perform_solana_preload for the canonical caller.
    def self.cached_vault_state
      return Current.vault_state if Current.vault_state_fetched

      Current.vault_state_fetched = true
      # race_condition_ttl damps the every-60s stampede: when the entry expires
      # under concurrent admin renders, the first reader bumps the expiry by
      # this window while it regenerates instead of all firing read_vault_state.
      Current.vault_state = Rails.cache.fetch(VAULT_STATE_CACHE_KEY, expires_in: 1.minute, race_condition_ttl: 5.seconds) do
        new.read_vault_state
      end
    rescue StandardError => e
      Rails.logger.warn("[solana] cached_vault_state failed: #{e.message}")
      Current.vault_state_error = true
      Current.vault_state = nil
    end

    # --- Pause / unpause (2-of-3) ---

    def build_pause_vault(cosigner_pubkey:, reason:)
      cosigner_bytes = Keypair.decode_base58(cosigner_pubkey)
      vault_pda, _ = vault_state_pda

      reason_bytes = reason.to_s.b.bytes.first(64)
      reason_bytes += [0] * (64 - reason_bytes.length)

      data = Transaction.anchor_discriminator("pause") + reason_bytes.pack("C*")

      serialized = build_partial_signed(
        accounts: [
          { pubkey: Keypair.admin.public_key_bytes, is_signer: true,  is_writable: true  },
          { pubkey: cosigner_bytes,                 is_signer: true,  is_writable: false },
          { pubkey: vault_pda,                      is_signer: false, is_writable: true  }
        ],
        data: data,
        additional_signers: [cosigner_bytes]
      )
      { serialized_tx: serialized, vault_pda: Keypair.encode_base58(vault_pda) }
    end

    def build_unpause_vault(cosigner_pubkey:)
      cosigner_bytes = Keypair.decode_base58(cosigner_pubkey)
      vault_pda, _ = vault_state_pda

      data = Transaction.anchor_discriminator("unpause")

      serialized = build_partial_signed(
        accounts: [
          { pubkey: Keypair.admin.public_key_bytes, is_signer: true,  is_writable: true  },
          { pubkey: cosigner_bytes,                 is_signer: true,  is_writable: false },
          { pubkey: vault_pda,                      is_signer: false, is_writable: true  }
        ],
        data: data,
        additional_signers: [cosigner_bytes]
      )
      { serialized_tx: serialized, vault_pda: Keypair.encode_base58(vault_pda) }
    end

    # --- Currency registry (2-of-3) ---

    # Build a partially-signed register_currency TX. Admin signs (pays
    # ATA rent), cosigner slot left for Phantom. `kind` is informational
    # (0 = stablecoin).
    def build_register_currency(cosigner_pubkey:, mint:, kind: 0)
      cosigner_bytes = Keypair.decode_base58(cosigner_pubkey)
      mint_bytes     = Keypair.decode_base58(mint)
      vault_pda, _   = vault_state_pda
      op_rev,    _   = op_rev_ata_pda(mint)

      data = Transaction.anchor_discriminator("register_currency") + Borsh.encode_u8(kind)

      serialized = build_partial_signed(
        accounts: [
          { pubkey: Keypair.admin.public_key_bytes, is_signer: true,  is_writable: true  },
          { pubkey: cosigner_bytes,                 is_signer: true,  is_writable: false },
          { pubkey: vault_pda,                      is_signer: false, is_writable: true  },
          { pubkey: mint_bytes,                     is_signer: false, is_writable: false },
          { pubkey: op_rev,                         is_signer: false, is_writable: true  },
          { pubkey: Transaction::TOKEN_PROGRAM_ID,   is_signer: false, is_writable: false },
          { pubkey: Transaction::SYSTEM_PROGRAM_ID,  is_signer: false, is_writable: false },
          { pubkey: Transaction::SYSVAR_RENT_PUBKEY, is_signer: false, is_writable: false }
        ],
        data: data,
        additional_signers: [cosigner_bytes]
      )
      { serialized_tx: serialized, op_rev_ata: Keypair.encode_base58(op_rev) }
    end

    # Build a partially-signed deactivate_currency TX (2-of-3).
    def build_deactivate_currency(cosigner_pubkey:, currency_idx:)
      cosigner_bytes = Keypair.decode_base58(cosigner_pubkey)
      vault_pda, _   = vault_state_pda

      data = Transaction.anchor_discriminator("deactivate_currency") +
             Borsh.encode_u8(currency_idx)

      serialized = build_partial_signed(
        accounts: [
          { pubkey: Keypair.admin.public_key_bytes, is_signer: true,  is_writable: true  },
          { pubkey: cosigner_bytes,                 is_signer: true,  is_writable: false },
          { pubkey: vault_pda,                      is_signer: false, is_writable: true  }
        ],
        data: data,
        additional_signers: [cosigner_bytes]
      )
      { serialized_tx: serialized }
    end

    # --- User account ---

    # UserAccount layout (v0.16): 8 disc + 32 wallet + 32 username + 8 seeds +
    # 4 entries + 4 wins + 4 cashes + 8 total_won + 1 bump + 32 _reserved = 133.
    USER_ACCOUNT_LEN = 133

    def check_user_account_status(wallet_address)
      user_pda, _ = user_account_pda(wallet_address)
      info = client.get_account_info(Keypair.encode_base58(user_pda))
      return :not_found unless info&.dig("value")

      data = Base64.decode64(info["value"]["data"][0])
      data.length == USER_ACCOUNT_LEN ? :ok : :needs_migration
    end

    # Ensure user's onchain account exists, creating it if missing.
    # `:needs_migration` indicates schema drift (old v0.15.1 UserAccount layout
    # at a different size) — bail loudly rather than auto-migrating.
    def ensure_user_account(wallet_address, username: nil)
      status = check_user_account_status(wallet_address)
      case status
      when :ok then nil
      when :not_found then create_user_account(wallet_address, username: username)
      when :needs_migration
        raise "UserAccount at unexpected size for #{wallet_address} — turf-vault " \
              "v0.16 schema drift; investigate manually (devnet teardown may be needed)."
      end
    end

    def create_user_account(wallet_address, username: nil)
      # v0.16: validate_username runs on-chain in handle_create_user_account
      # and rejects < 3 non-null bytes with `UsernameTooShort` (0x1786).
      # Catch this client-side with a clearer error than the on-chain code.
      if username.nil? || username.to_s.strip.length < 3
        raise ArgumentError,
              "create_user_account requires a username of >= 3 chars " \
              "(got: #{username.inspect}). v0.16 enforces this on-chain " \
              "(VaultError::UsernameTooShort). Pass username: user.username."
      end

      admin = Keypair.admin
      user_pda, _bump = user_account_pda(wallet_address)
      wallet_bytes = Keypair.decode_base58(wallet_address)

      data = Transaction.anchor_discriminator("create_user_account") +
             Borsh.encode_pubkey(wallet_bytes) +
             username_bytes32(username)

      tx = build_tx(admin)
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: admin.public_key_bytes,         is_signer: true,  is_writable: true  },
          { pubkey: user_pda,                       is_signer: false, is_writable: true  },
          { pubkey: Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false }
        ],
        data: data
      )

      signature = client.send_and_confirm(tx.serialize_base64)
      { signature: signature, pda: Keypair.encode_base58(user_pda) }
    end

    # Server-signed set_username for custodial users (web2).
    def set_username(wallet_address, username, user_keypair:)
      raise "user_keypair required for a server-signed set_username" unless user_keypair
      admin = Keypair.admin
      user_pda, _ = user_account_pda(wallet_address)
      wallet_bytes = Keypair.decode_base58(wallet_address)

      data = Transaction.anchor_discriminator("set_username") + username_bytes32(username)

      tx = build_tx(admin)
      tx.add_signer(user_keypair)
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: wallet_bytes, is_signer: true,  is_writable: false },
          { pubkey: user_pda,     is_signer: false, is_writable: true  }
        ],
        data: data
      )
      signature = client.send_and_confirm(tx.serialize_base64)
      { signature: signature }
    end

    def build_set_username(wallet_address, username)
      user_pda, _ = user_account_pda(wallet_address)
      wallet_bytes = Keypair.decode_base58(wallet_address)

      data = Transaction.anchor_discriminator("set_username") + username_bytes32(username)

      serialized = build_partial_signed(
        accounts: [
          { pubkey: wallet_bytes, is_signer: true,  is_writable: false },
          { pubkey: user_pda,     is_signer: false, is_writable: true  }
        ],
        data: data,
        additional_signers: [wallet_bytes]
      )
      { serialized_tx: serialized }
    end

    # Read on-chain UserAccount (v0.16 layout).
    #
    # v0.16 strips balance/total_deposited/total_withdrawn/daily_window_*.
    # Replaces them with on-chain stat counters (entries, wins, cashes,
    # total_won).
    #
    # Compatibility shim: callers (display_balance, withdraw gate) expect
    # `:balance` / `:balance_dollars`. Since custodial balance is gone in
    # v0.16, we surface the user's USDC ATA balance under the same keys —
    # functionally what "balance available" means for the user is now their
    # ATA balance.
    def sync_balance(wallet_address, commitment: "confirmed")
      user_pda, _ = user_account_pda(wallet_address)
      pda_base58 = Keypair.encode_base58(user_pda)

      info = client.get_account_info(pda_base58, commitment: commitment)
      return nil unless info&.dig("value")

      data = Base64.decode64(info["value"]["data"][0])

      offset = 8 # skip discriminator
      _wallet, offset = Borsh.decode_pubkey(data, offset)
      raw_username = data.byteslice(offset, 32).to_s
      username = raw_username.bytes.take_while { |byte| byte != 0 }
                             .pack("C*").force_encoding("UTF-8").presence
      offset += 32
      seeds,       offset = Borsh.decode_u64(data, offset)
      entries,     offset = Borsh.decode_u32(data, offset)
      wins,        offset = Borsh.decode_u32(data, offset)
      cashes,      offset = Borsh.decode_u32(data, offset)
      total_won,   offset = Borsh.decode_u64(data, offset)

      # ATA-side USDC balance — replaces the dropped UserAccount.balance.
      ata_balance_lamports = fetch_usdc_ata_balance_lamports(wallet_address)

      {
        # v0.16 fields
        username:           username,
        seeds:              seeds,
        entries:            entries,
        wins:               wins,
        cashes:             cashes,
        total_won:          total_won,
        total_won_dollars:  Config.lamports_to_dollars(total_won),
        # Back-compat keys (USDC ATA balance — functionally "available balance")
        balance:            ata_balance_lamports,
        balance_dollars:    Config.lamports_to_dollars(ata_balance_lamports),
        # Legacy v0.15.1 fields callers may still read — surface zero so
        # nil-safety holds without lying about behavior.
        total_deposited:    0,
        total_withdrawn:    0,
        daily_withdrawn:    0,
        daily_window_start: 0
      }
    end

    # --- Contest creation ---

    # v0.16 build_create_contest. Admin pays SOL rent (payer slot), creator
    # signs the prize-pool USDC transfer (creator slot). `entry_fee_by_currency`
    # is a 16-element array of u64 lamports — index = currency_idx, 0 = not
    # accepted for this contest.
    def build_create_contest(wallet_address, contest_slug,
                             entry_fee_by_currency:, max_entries:,
                             payout_amounts:, prize_pool:, season_id: nil,
                             lock_timestamp: 0, admin_signs: true)
      spec = create_contest_instruction(
        wallet_address,
        contest_slug,
        entry_fee_by_currency: entry_fee_by_currency,
        max_entries: max_entries,
        payout_amounts: payout_amounts,
        prize_pool: prize_pool,
        season_id: season_id,
        lock_timestamp: lock_timestamp
      )

      wallet_bytes = Keypair.decode_base58(wallet_address)

      serialized =
        if admin_signs
          build_partial_signed(
            accounts: spec[:accounts],
            data: spec[:data],
            additional_signers: [wallet_bytes],
            # Contest-create is the flow that died on mainnet BlockhashNotFound
            # when a flagged Phantom warning ate the ~90s blockhash window.
            durable_nonce: durable_nonce_config
          )
        else
          # Phantom-FIRST contest create: leave both admin and creator signature
          # slots empty. The browser signs first, then the server validates,
          # cosigns, simulates, and broadcasts. Fresh blockhash only; a durable
          # nonce plus wallet-injected guard instructions is too brittle here.
          build_partial_unsigned(
            accounts: spec[:accounts],
            data: spec[:data],
            additional_signers: [Keypair.admin.public_key_bytes, wallet_bytes],
            durable_nonce: nil
          )
        end

      { serialized_tx: serialized, contest_pda: Keypair.encode_base58(spec[:contest_pda]) }
    end

    def create_contest_instruction(wallet_address, contest_slug,
                                   entry_fee_by_currency:, max_entries:,
                                   payout_amounts:, prize_pool:, season_id: nil,
                                   lock_timestamp: 0)
      wallet_bytes  = Keypair.decode_base58(wallet_address)
      contest_id    = Digest::SHA256.digest(contest_slug)
      contest_pda_addr, _ = contest_pda(contest_slug)
      prize_pool_addr,  _ = prize_pool_pda(contest_slug)
      vault_pda,    _ = vault_state_pda

      usdc_mint   = Keypair.decode_base58(Config::USDC_MINT)
      creator_ata, _ = Solana::SplToken.find_associated_token_address(wallet_address, Config::USDC_MINT)

      season_id ||= SeasonConfig.current_season_id

      fee_array = pad_fee_array(entry_fee_by_currency)

      data = Transaction.anchor_discriminator("create_contest") +
             Borsh.encode_bytes32(contest_id) +
             Borsh.encode_u32(season_id) +
             fee_array.map { |amt| Borsh.encode_u64(amt) }.join +
             Borsh.encode_u32(max_entries) +
             Borsh.encode_vec(payout_amounts) { |amt| Borsh.encode_u64(amt) } +
             Borsh.encode_u64(prize_pool) +
             Borsh.encode_i64(lock_timestamp.to_i)

      {
        accounts: [
          { pubkey: Keypair.admin.public_key_bytes, is_signer: true,  is_writable: true  }, # payer
          { pubkey: wallet_bytes,                   is_signer: true,  is_writable: true  }, # creator
          { pubkey: vault_pda,                      is_signer: false, is_writable: false }, # vault_state
          { pubkey: contest_pda_addr,               is_signer: false, is_writable: true  }, # contest (init)
          { pubkey: prize_pool_addr,                is_signer: false, is_writable: true  }, # prize_pool (init)
          { pubkey: usdc_mint,                      is_signer: false, is_writable: false }, # payout_mint
          { pubkey: creator_ata,                    is_signer: false, is_writable: true  }, # creator_token_account
          { pubkey: Transaction::TOKEN_PROGRAM_ID,   is_signer: false, is_writable: false },
          { pubkey: Transaction::SYSTEM_PROGRAM_ID,  is_signer: false, is_writable: false },
          { pubkey: Transaction::SYSVAR_RENT_PUBKEY, is_signer: false, is_writable: false }
        ],
        data: data,
        contest_pda: contest_pda_addr
      }
    end

    # Server-funded create_contest — admin signs both payer and creator slots.
    # Used by operator scripts / Rails console. Funds prize pool from admin
    # USDC ATA → prize_pool PDA.
    def create_contest_server_funded(contest_slug:, entry_fee_by_currency:,
                                     max_entries:, payout_amounts:, prize_pool:,
                                     season_id: nil, lock_timestamp: 0)
      admin = Keypair.admin
      contest_id = Digest::SHA256.digest(contest_slug)
      contest_pda_addr, _ = contest_pda(contest_slug)
      prize_pool_addr,  _ = prize_pool_pda(contest_slug)
      vault_pda,    _ = vault_state_pda

      usdc_mint  = Keypair.decode_base58(Config::USDC_MINT)
      admin_b58  = Keypair.encode_base58(admin.public_key_bytes)
      creator_ata, _ = Solana::SplToken.find_associated_token_address(admin_b58, Config::USDC_MINT)

      season_id ||= SeasonConfig.current_season_id

      fee_array = pad_fee_array(entry_fee_by_currency)

      data = Transaction.anchor_discriminator("create_contest") +
             Borsh.encode_bytes32(contest_id) +
             Borsh.encode_u32(season_id) +
             fee_array.map { |amt| Borsh.encode_u64(amt) }.join +
             Borsh.encode_u32(max_entries) +
             Borsh.encode_vec(payout_amounts) { |amt| Borsh.encode_u64(amt) } +
             Borsh.encode_u64(prize_pool) +
             Borsh.encode_i64(lock_timestamp.to_i)

      tx = build_tx(admin)
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: admin.public_key_bytes,         is_signer: true,  is_writable: true  }, # payer
          { pubkey: admin.public_key_bytes,         is_signer: true,  is_writable: true  }, # creator (== admin, dedup'd)
          { pubkey: vault_pda,                      is_signer: false, is_writable: false },
          { pubkey: contest_pda_addr,               is_signer: false, is_writable: true  },
          { pubkey: prize_pool_addr,                is_signer: false, is_writable: true  },
          { pubkey: usdc_mint,                      is_signer: false, is_writable: false },
          { pubkey: creator_ata,                    is_signer: false, is_writable: true  },
          { pubkey: Transaction::TOKEN_PROGRAM_ID,   is_signer: false, is_writable: false },
          { pubkey: Transaction::SYSTEM_PROGRAM_ID,  is_signer: false, is_writable: false },
          { pubkey: Transaction::SYSVAR_RENT_PUBKEY, is_signer: false, is_writable: false }
        ],
        data: data
      )

      serialized = tx.serialize_base64
      tx_sig = client.send_transaction(serialized)

      deadline = Time.now + 30
      loop do
        sleep 1
        status = client.confirm_transaction(tx_sig).dig("value", 0)
        if status
          raise "create_contest TX failed: #{status["err"]}" if status["err"]
          break if %w[confirmed finalized].include?(status["confirmationStatus"])
        end
        raise "create_contest TX confirmation timeout (sig=#{tx_sig})" if Time.now > deadline
      end

      { tx_signature: tx_sig, contest_pda: Keypair.encode_base58(contest_pda_addr) }
    end

    # --- Contest lifecycle ---

    # Set (or clear) a contest's derived lock timestamp (1-of-3, admin alone
    # signs server-side). `lock_timestamp` is Unix seconds; 0 clears the lock
    # (enterable indefinitely). "Lock now" = pass Time.current.to_i. The chain
    # rejects entries once its Clock time >= lock_timestamp — this is the
    # authoritative lock (v0.17 set_contest_lock_time instruction); the Rails
    # `locks_at` checks are advisory UX only. Rejected on-chain once the
    # contest is concluded (Settled/Cancelled → ContestAlreadySettled 6006).
    def set_contest_lock_time(contest_slug, lock_timestamp)
      admin = Keypair.admin
      c_pda, _ = contest_pda(contest_slug)
      vault_pda, _ = vault_state_pda

      data = Transaction.anchor_discriminator("set_contest_lock_time") +
             Borsh.encode_i64(lock_timestamp.to_i)

      tx = build_tx(admin)
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: admin.public_key_bytes, is_signer: true,  is_writable: true  },
          # cosigner: Option<Signer> — None for a routine 1-of-3 pre-lock set
          # (v0.19, #5). Anchor encodes a None optional account as the program
          # ID. Amending an ALREADY-PASSED lock needs a real 2-of-3 cosigner
          # (separate cosign flow) — see ContestsController guard.
          { pubkey: @program_id,            is_signer: false, is_writable: false },
          { pubkey: vault_pda,              is_signer: false, is_writable: false },
          { pubkey: c_pda,                  is_signer: false, is_writable: true  }
        ],
        data: data
      )
      signature = client.send_and_confirm(tx.serialize_base64)
      { signature: signature }
    end

    # Build a Phantom-signable set_contest_lock_time TX (1-of-3). The admin's
    # Phantom wallet (which must be a vault signer — e.g. Alex's key) occupies
    # the `admin` signer slot; the bot stays fee payer (slot 0) so the user only
    # signs, paying no SOL. Mirrors the create_contest dual-signer pattern
    # (build_create_contest): bot partial-signs, Phantom fills its placeholder
    # client-side. Returns base64 for the client to sign + broadcast.
    def build_set_contest_lock_time(contest_slug, lock_timestamp, admin_pubkey:)
      admin_bytes = Keypair.decode_base58(admin_pubkey)
      c_pda, _ = contest_pda(contest_slug)
      vault_pda, _ = vault_state_pda

      data = Transaction.anchor_discriminator("set_contest_lock_time") +
             Borsh.encode_i64(lock_timestamp.to_i)

      serialized = build_partial_signed(
        accounts: [
          { pubkey: admin_bytes, is_signer: true,  is_writable: true  }, # admin == Phantom (vault signer)
          { pubkey: @program_id, is_signer: false, is_writable: false }, # cosigner: None (1-of-3 pre-lock; v0.19 #5)
          { pubkey: vault_pda,   is_signer: false, is_writable: false }, # vault_state
          { pubkey: c_pda,       is_signer: false, is_writable: true  }  # contest
        ],
        data: data,
        additional_signers: [admin_bytes]
      )
      { serialized_tx: serialized }
    end

    # Set (or clear) a contest's conclusion timestamp, server-signed (1-of-3).
    # Parallel to set_contest_lock_time. Once chain time passes it the contest
    # has concluded and the lock time can no longer change. 0 clears it.
    def set_contest_conclusion_time(contest_slug, conclusion_timestamp)
      admin = Keypair.admin
      c_pda, _ = contest_pda(contest_slug)
      vault_pda, _ = vault_state_pda

      data = Transaction.anchor_discriminator("set_contest_conclusion_time") +
             Borsh.encode_i64(conclusion_timestamp.to_i)

      tx = build_tx(admin)
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: admin.public_key_bytes, is_signer: true,  is_writable: true  },
          # cosigner: Option<Signer> — None for a 1-of-3 first set; amending an
          # already-SET conclusion needs a 2-of-3 cosigner (v0.19, #5).
          { pubkey: @program_id,            is_signer: false, is_writable: false },
          { pubkey: vault_pda,              is_signer: false, is_writable: false },
          { pubkey: c_pda,                  is_signer: false, is_writable: true  }
        ],
        data: data
      )
      signature = client.send_and_confirm(tx.serialize_base64)
      { signature: signature }
    end

    # Phantom-signable set_contest_conclusion_time (1-of-3). Mirrors
    # build_set_contest_lock_time: bot fee payer, admin's Phantom (a vault
    # signer) signs the `admin` slot. Returns base64 for the client to sign.
    def build_set_contest_conclusion_time(contest_slug, conclusion_timestamp, admin_pubkey:)
      admin_bytes = Keypair.decode_base58(admin_pubkey)
      c_pda, _ = contest_pda(contest_slug)
      vault_pda, _ = vault_state_pda

      data = Transaction.anchor_discriminator("set_contest_conclusion_time") +
             Borsh.encode_i64(conclusion_timestamp.to_i)

      serialized = build_partial_signed(
        accounts: [
          { pubkey: admin_bytes, is_signer: true,  is_writable: true  },
          { pubkey: @program_id, is_signer: false, is_writable: false }, # cosigner: None (1-of-3 first set; v0.19 #5)
          { pubkey: vault_pda,   is_signer: false, is_writable: false },
          { pubkey: c_pda,       is_signer: false, is_writable: true  }
        ],
        data: data,
        additional_signers: [admin_bytes]
      )
      { serialized_tx: serialized }
    end

    # Build cancel_contest TX (2-of-3). Refunds prize_pool → creator ATA.
    def build_cancel_contest(contest_slug, creator_pubkey:, cosigner_pubkey:)
      cosigner_bytes = Keypair.decode_base58(cosigner_pubkey)
      c_pda, _ = contest_pda(contest_slug)
      prize_pool_addr, _ = prize_pool_pda(contest_slug)
      vault_pda, _ = vault_state_pda
      usdc_mint   = Keypair.decode_base58(Config::USDC_MINT)
      creator_ata, _ = Solana::SplToken.find_associated_token_address(creator_pubkey, Config::USDC_MINT)

      data = Transaction.anchor_discriminator("cancel_contest")

      serialized = build_partial_signed(
        accounts: [
          { pubkey: Keypair.admin.public_key_bytes, is_signer: true,  is_writable: true  },
          { pubkey: cosigner_bytes,                 is_signer: true,  is_writable: false },
          { pubkey: vault_pda,                      is_signer: false, is_writable: false },
          { pubkey: c_pda,                          is_signer: false, is_writable: true  },
          { pubkey: prize_pool_addr,                is_signer: false, is_writable: true  },
          { pubkey: usdc_mint,                      is_signer: false, is_writable: false },
          { pubkey: creator_ata,                    is_signer: false, is_writable: true  },
          { pubkey: Transaction::TOKEN_PROGRAM_ID,  is_signer: false, is_writable: false }
        ],
        data: data,
        additional_signers: [cosigner_bytes]
      )
      { serialized_tx: serialized }
    end

    # --- Entries ---

    # v0.16 unified enter_contest. Handles both web2 and web3:
    #   - web3: server builds a partial-signed TX with admin (payer) pre-signed;
    #     Phantom signs as `user` and broadcasts (use `build_enter_contest` below).
    #   - web2: server signs BOTH as payer (admin keypair) and user (custodial
    #     keypair) and broadcasts directly (this method).
    #
    # `currency_idx` selects the on-chain currency slot to spend from (0 = USDC,
    # 1 = USDT, etc.). Defaults to 0 for the v1 UX. The contest's
    # entry_fee_by_currency[idx] determines the amount.
    def enter_contest(wallet_address, contest_slug, entry_num, currency_idx: 0,
                      user_keypair:, season_id: nil)
      raise "user_keypair required for managed-wallet entry (v0.16 OPSEC)" unless user_keypair

      admin = Keypair.admin
      vault_pda, _ = vault_state_pda
      user_pda,  _ = user_account_pda(wallet_address)
      c_pda,     _ = contest_pda(contest_slug)
      e_pda,     _ = entry_pda(contest_slug, wallet_address, entry_num)
      season_id ||= SeasonConfig.current_season_id
      s_pda,     _ = season_pda(season_id)

      mint_b58    = mint_for_currency_idx(currency_idx)
      currency_mint_bytes = Keypair.decode_base58(mint_b58)
      user_ata,   _ = Solana::SplToken.find_associated_token_address(wallet_address, mint_b58)
      op_rev,     _ = op_rev_ata_pda(mint_b58)

      data = Transaction.anchor_discriminator("enter_contest") +
             Borsh.encode_u32(entry_num) +
             Borsh.encode_u8(currency_idx)

      signature = with_account_init_retry do
        tx = build_tx(admin)
        tx.add_signer(user_keypair)
        tx.add_instruction(
          program_id: @program_id,
          accounts: enter_contest_accounts(
            payer_bytes:       admin.public_key_bytes,
            user_bytes:        user_keypair.public_key_bytes,
            user_pda:          user_pda,
            vault_pda:         vault_pda,
            contest_pda:       c_pda,
            entry_pda:         e_pda,
            currency_mint:     currency_mint_bytes,
            user_token_account: user_ata,
            op_rev_ata:        op_rev,
            season_pda:        s_pda
          ),
          data: data
        )
        client.send_and_confirm(tx.serialize_base64)
      end
      { signature: signature, entry_pda: Keypair.encode_base58(e_pda) }
    end

    # Server-signed managed-wallet (web2) USDC contest entry — the web2 funding
    # fallback in the unified token -> USDC priority (USDT is intentionally NOT
    # offered to web2: payouts are USDC, so web2 users won't hold USDT).
    #
    # When a managed user has no entry token but enough USDC, the SERVER signs
    # the EXISTING on-chain `enter_contest` (USDC) instruction on the user's
    # behalf — it can, because it holds the user's managed keypair
    # (encrypted_web2_solana_private_key, decrypted via Solana::Keypair). This
    # is what lets a USDC contest payout fund the next entry: settle pays winners
    # into their USDC ATA, and this pulls the next entry fee from that same ATA.
    #
    # NO turf-vault program change: this delegates to #enter_contest with
    # currency_idx HARD-PINNED to USDC. The pin (not a caller-supplied index)
    # makes a USDT leak into the web2 path structurally impossible.
    #
    # SIGNER CONSISTENCY (the load-bearing invariant): everything — the on-chain
    # `user` signer, the USDC ATA owner, and the UserAccount PDA — is derived
    # from user.web2_solana_address, and the managed keypair we sign with is
    # asserted to match it. NEVER user.solana_address (which prefers the web3
    # address): a managed+phantom combo account would otherwise desync the
    # signer from the ATA/PDA and the tx would fail (or target the wrong account).
    #
    # ATOMIC / no-strand: the SPL USDC transfer + entry-PDA init are ONE
    # instruction, so an underfunded ATA fails the whole tx — nothing is
    # consumed or created (no strand, no double-charge). Returns
    # { signature:, entry_pda: } exactly like #enter_contest, so the caller's
    # durable-capture write (ContestsController#enter) is byte-for-byte identical
    # to the token path.
    USDC_CURRENCY_IDX = 0

    def enter_contest_with_usdc(user:, contest:, entry_num:)
      wallet_address = user.web2_solana_address
      raise ArgumentError, "enter_contest_with_usdc requires a managed (web2) wallet" if wallet_address.blank?

      user_keypair = user.solana_keypair
      raise "Managed wallet missing keypair (cannot sign USDC entry)" unless user_keypair

      # LOUD signer guard: the keypair we sign with MUST own web2_solana_address,
      # or the on-chain `user` signer would not match the ATA/user_pda derived
      # from that address. Both come from the same `user`, so this only trips on
      # a corrupted row — fail closed rather than broadcast a doomed/wrong tx.
      unless user_keypair.public_key_bytes == Keypair.decode_base58(wallet_address)
        raise "Managed keypair does not own web2_solana_address (signer/ATA desync guard)"
      end

      # Bootstrap the accounts the irreversible enter_contest spends through, so
      # a caller can't reach the broadcast with a missing UserAccount PDA or USDC
      # ATA (would 0xbc4 / AccountNotInitialized).
      ensure_user_account(wallet_address, username: user.username)
      ensure_ata(wallet_address, mint: Config::USDC_MINT)

      enter_contest(
        wallet_address,
        contest.slug,
        entry_num,
        currency_idx: USDC_CURRENCY_IDX,
        user_keypair: user_keypair,
        season_id: contest.season_id
      )
    end

    # Build an enter_contest TX for Phantom co-sign.
    #
    # Phantom-FIRST (default, admin_signs: false): returns a FULLY-UNSIGNED tx —
    # BOTH the admin (payer) and user slots are empty. Phantom signs FIRST
    # (clearing the multi-signer-order "could be malicious" banner), then the
    # server fills the admin slot via cosign_and_broadcast_entry and broadcasts.
    # The admin is still fee payer + nonce authority + rent subsidizer; it just
    # signs SECOND now instead of first.
    #
    # admin_signs: true preserves the legacy server-first behavior (admin signs
    # at build time, user slot empty) for any caller/script that broadcasts
    # client-side. The Phantom USDC entry UI uses the default (false).
    #
    # Replaces v0.15.1's build_enter_contest_direct.
    def build_enter_contest(wallet_address, contest_slug, entry_num, currency_idx: 0, season_id: nil, admin_signs: false)
      wallet_bytes = Keypair.decode_base58(wallet_address)
      vault_pda,   _ = vault_state_pda
      user_pda,    _ = user_account_pda(wallet_address)
      c_pda,       _ = contest_pda(contest_slug)
      e_pda,       _ = entry_pda(contest_slug, wallet_address, entry_num)
      season_id ||= SeasonConfig.current_season_id
      s_pda,       _ = season_pda(season_id)

      mint_b58    = mint_for_currency_idx(currency_idx)
      currency_mint_bytes = Keypair.decode_base58(mint_b58)
      user_ata,   _ = Solana::SplToken.find_associated_token_address(wallet_address, mint_b58)
      op_rev,     _ = op_rev_ata_pda(mint_b58)

      data = Transaction.anchor_discriminator("enter_contest") +
             Borsh.encode_u32(entry_num) +
             Borsh.encode_u8(currency_idx)

      accounts = enter_contest_accounts(
        payer_bytes:        Keypair.admin.public_key_bytes,
        user_bytes:         wallet_bytes,
        user_pda:           user_pda,
        vault_pda:          vault_pda,
        contest_pda:        c_pda,
        entry_pda:          e_pda,
        currency_mint:      currency_mint_bytes,
        user_token_account: user_ata,
        op_rev_ata:         op_rev,
        season_pda:         s_pda
      )

      # ENTRY TXS DO NOT USE THE DURABLE NONCE (mainnet incident 2026-06-11).
      # Two reasons, both fatal:
      #   1. A durable-nonce tx is only recognized when advanceNonceAccount is
      #      instruction 0 — and Phantom INJECTS Lighthouse guard instructions
      #      at signing time at positions we don't control. When the injection
      #      lands before the advance, validators treat the nonce value as a
      #      plain (unknown) blockhash and reject with BlockhashNotFound at
      #      sendTransaction preflight.
      #   2. One nonce account anchors ONE in-flight tx at a time — a shared
      #      operator nonce under concurrent user entries is a contention bug.
      # Entries re-prepare seconds before signing, so a fresh recent blockhash
      # (~60-90s validity) comfortably covers the Phantom signing window. The
      # durable nonce remains for OPERATOR flows (lock-time etc. via
      # build_partial_signed), where a slow human cosign is the actual problem.
      dn = nil

      serialized =
        if admin_signs
          # Legacy server-first: admin signs now, only the user slot is left empty.
          build_partial_signed(
            accounts: accounts, data: data,
            additional_signers: [wallet_bytes], durable_nonce: dn
          )
        else
          # Phantom-first: BOTH slots empty. additional_signers ordered admin
          # FIRST (fee-payer ordering for the gem's keyless build), then user.
          build_partial_unsigned(
            accounts: accounts, data: data,
            additional_signers: [Keypair.admin.public_key_bytes, wallet_bytes],
            durable_nonce: dn
          )
        end
      { serialized_tx: serialized, entry_pda: Keypair.encode_base58(e_pda) }
    end

    # Atomic token-funded entry (no SPL transfer; consumes EntryTokenAccount).
    # `user_keypair` required: token owner must sign the consume (OPSEC-004).
    # Used by ContestsController#enter for web2 users.
    def enter_contest_with_token(wallet_address, contest_slug, entry_num, entry_token_pda_b58,
                                 user_keypair:, season_id: nil)
      raise "user_keypair required (OPSEC-004)" unless user_keypair
      admin = Keypair.admin
      vault_pda,   _ = vault_state_pda
      user_pda,    _ = user_account_pda(wallet_address)
      c_pda,       _ = contest_pda(contest_slug)
      e_pda,       _ = entry_pda(contest_slug, wallet_address, entry_num)
      token_pda_bytes = Keypair.decode_base58(entry_token_pda_b58)
      season_id ||= SeasonConfig.current_season_id
      s_pda,       _ = season_pda(season_id)

      data = Transaction.anchor_discriminator("enter_contest_with_token") +
             Borsh.encode_u32(entry_num)

      signature = with_account_init_retry do
        tx = build_tx(admin)
        tx.add_signer(user_keypair)
        tx.add_instruction(
          program_id: @program_id,
          accounts: [
            { pubkey: admin.public_key_bytes,         is_signer: true,  is_writable: true  }, # payer
            { pubkey: user_keypair.public_key_bytes,  is_signer: true,  is_writable: true  }, # user
            { pubkey: user_pda,                       is_signer: false, is_writable: true  },
            { pubkey: vault_pda,                      is_signer: false, is_writable: false },
            { pubkey: c_pda,                          is_signer: false, is_writable: true  },
            { pubkey: e_pda,                          is_signer: false, is_writable: true  },
            { pubkey: token_pda_bytes,                is_signer: false, is_writable: true  },
            { pubkey: s_pda,                          is_signer: false, is_writable: false },
            { pubkey: Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false }
          ],
          data: data
        )
        client.send_and_confirm(tx.serialize_base64)
      end
      invalidate_entry_tokens_cache(wallet_address)
      { signature: signature, entry_pda: Keypair.encode_base58(e_pda) }
    end

    # Build a partially-signed enter_contest_with_token TX (Phantom wallet).
    # Admin signs as payer, Phantom signs as user.
    def build_enter_contest_with_token(wallet_address, contest_slug, entry_num, entry_token_pda_b58,
                                       season_id: nil)
      wallet_bytes = Keypair.decode_base58(wallet_address)
      vault_pda,   _ = vault_state_pda
      user_pda,    _ = user_account_pda(wallet_address)
      c_pda,       _ = contest_pda(contest_slug)
      e_pda,       _ = entry_pda(contest_slug, wallet_address, entry_num)
      token_pda_bytes = Keypair.decode_base58(entry_token_pda_b58)
      season_id ||= SeasonConfig.current_season_id
      s_pda,       _ = season_pda(season_id)

      data = Transaction.anchor_discriminator("enter_contest_with_token") +
             Borsh.encode_u32(entry_num)

      serialized = build_partial_signed(
        accounts: [
          { pubkey: Keypair.admin.public_key_bytes, is_signer: true,  is_writable: true  },
          { pubkey: wallet_bytes,                   is_signer: true,  is_writable: true  },
          { pubkey: user_pda,                       is_signer: false, is_writable: true  },
          { pubkey: vault_pda,                      is_signer: false, is_writable: false },
          { pubkey: c_pda,                          is_signer: false, is_writable: true  },
          { pubkey: e_pda,                          is_signer: false, is_writable: true  },
          { pubkey: token_pda_bytes,                is_signer: false, is_writable: true  },
          { pubkey: s_pda,                          is_signer: false, is_writable: false },
          { pubkey: Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false }
        ],
        data: data,
        additional_signers: [wallet_bytes]
      )
      { serialized_tx: serialized, entry_pda: Keypair.encode_base58(e_pda) }
    end

    # --- Settle ---

    # Settle a contest (2-of-3). v0.16 changes:
    #   - remaining_accounts pattern is now TRIPLES: [user_account_pda,
    #     contest_entry_pda, winner_usdc_ata] per winner.
    #   - SPL CPI per winner from prize_pool → winner's USDC ATA.
    #   - TX prepends a set_compute_unit_limit(400_000) instruction to handle
    #     the increased CU cost (spec §10.1 / §11 Q7).
    def settle_contest(contest_slug, settlements, cosigner_keypair: nil)
      admin = Keypair.admin
      cosigner = cosigner_keypair || admin
      c_pda, _ = contest_pda(contest_slug)
      vault_pda, _ = vault_state_pda
      prize_pool_addr, _ = prize_pool_pda(contest_slug)
      usdc_mint  = Keypair.decode_base58(Config::USDC_MINT)

      settlement_data = settlements.map do |s|
        Borsh.encode_pubkey(Keypair.decode_base58(s[:wallet])) +
          Borsh.encode_u32(s[:entry_num]) +
          Borsh.encode_u32(s[:rank]) +
          Borsh.encode_u64(s[:payout])
      end

      data = Transaction.anchor_discriminator("settle_contest") +
             Borsh.encode_u32(settlements.length) +
             settlement_data.join

      remaining = settle_remaining_accounts(contest_slug, settlements)

      tx = build_tx(admin)
      tx.add_signer(cosigner) if cosigner != admin
      tx.add_instruction(**compute_unit_limit_ix(SETTLE_COMPUTE_UNIT_LIMIT))
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: admin.public_key_bytes,        is_signer: true,  is_writable: true  },
          { pubkey: cosigner.public_key_bytes,     is_signer: true,  is_writable: false },
          { pubkey: vault_pda,                     is_signer: false, is_writable: false },
          { pubkey: c_pda,                         is_signer: false, is_writable: true  },
          { pubkey: prize_pool_addr,               is_signer: false, is_writable: true  },
          { pubkey: usdc_mint,                     is_signer: false, is_writable: false },
          { pubkey: Transaction::TOKEN_PROGRAM_ID, is_signer: false, is_writable: false }
        ] + remaining,
        data: data
      )

      signature = client.send_and_confirm(tx.serialize_base64)
      { signature: signature }
    end

    # Build a partially-signed settle_contest TX for multisig cosigning.
    def build_settle_contest(contest_slug, settlements, cosigner_pubkey:)
      c_pda, _ = contest_pda(contest_slug)
      vault_pda, _ = vault_state_pda
      prize_pool_addr, _ = prize_pool_pda(contest_slug)
      usdc_mint  = Keypair.decode_base58(Config::USDC_MINT)
      cosigner_bytes = Keypair.decode_base58(cosigner_pubkey)

      settlement_data = settlements.map do |s|
        Borsh.encode_pubkey(Keypair.decode_base58(s[:wallet])) +
          Borsh.encode_u32(s[:entry_num]) +
          Borsh.encode_u32(s[:rank]) +
          Borsh.encode_u64(s[:payout])
      end

      data = Transaction.anchor_discriminator("settle_contest") +
             Borsh.encode_u32(settlements.length) +
             settlement_data.join

      remaining = settle_remaining_accounts(contest_slug, settlements)

      tx = build_tx(Keypair.admin)
      tx.add_instruction(**compute_unit_limit_ix(SETTLE_COMPUTE_UNIT_LIMIT))
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: Keypair.admin.public_key_bytes, is_signer: true,  is_writable: true  },
          { pubkey: cosigner_bytes,                 is_signer: true,  is_writable: false },
          { pubkey: vault_pda,                      is_signer: false, is_writable: false },
          { pubkey: c_pda,                          is_signer: false, is_writable: true  },
          { pubkey: prize_pool_addr,                is_signer: false, is_writable: true  },
          { pubkey: usdc_mint,                      is_signer: false, is_writable: false },
          { pubkey: Transaction::TOKEN_PROGRAM_ID,  is_signer: false, is_writable: false }
        ] + remaining,
        data: data
      )
      serialized = tx.serialize_partial_base64(additional_signers: [cosigner_bytes])
      { serialized_tx: serialized, contest_slug: contest_slug }
    end

    # --- Close ---

    # close_contest (v0.16): 1-of-3 vault signer. Sweeps any prize-pool dust
    # to the op_rev USDC ATA, then closes both the prize_pool ATA and the
    # Contest PDA. Reclaims rent to admin.
    def close_contest(contest_slug)
      admin = Keypair.admin
      c_pda,            _ = contest_pda(contest_slug)
      prize_pool_addr,  _ = prize_pool_pda(contest_slug)
      vault_pda,        _ = vault_state_pda
      op_rev_usdc,      _ = op_rev_ata_pda(Config::USDC_MINT)
      usdc_mint           = Keypair.decode_base58(Config::USDC_MINT)

      data = Transaction.anchor_discriminator("close_contest")

      tx = build_tx(admin)
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: admin.public_key_bytes,        is_signer: true,  is_writable: true  },
          { pubkey: vault_pda,                     is_signer: false, is_writable: false },
          { pubkey: c_pda,                         is_signer: false, is_writable: true  },
          { pubkey: prize_pool_addr,               is_signer: false, is_writable: true  },
          { pubkey: usdc_mint,                     is_signer: false, is_writable: false },
          { pubkey: op_rev_usdc,                   is_signer: false, is_writable: true  },
          { pubkey: Transaction::TOKEN_PROGRAM_ID, is_signer: false, is_writable: false }
        ],
        data: data
      )

      signature = client.send_and_confirm(tx.serialize_base64)
      { signature: signature }
    end

    # Derive the treasury USDC ATA for a given mint — the ATA owned by
    # VaultState.treasury_authority (the Squads vault PDA). This is the
    # sweep destination for sweep_operator_revenue. Returns base58.
    def treasury_ata_for(mint)
      authority = read_vault_state[:treasury_authority]
      ata_bytes, _ = Solana::SplToken.find_associated_token_address(authority, mint)
      Keypair.encode_base58(ata_bytes)
    end

    # --- Sweep operator revenue (2-of-3) ---

    # Build a partially-signed sweep_operator_revenue TX. `amount` of 0
    # sweeps the whole op_rev ATA. `treasury_ata_pubkey` must be a USDC ATA
    # owned by VaultState.treasury_authority (the Squads vault PDA).
    def build_sweep_operator_revenue(cosigner_pubkey:, currency_mint:, treasury_ata_pubkey:, amount: 0)
      cosigner_bytes = Keypair.decode_base58(cosigner_pubkey)
      mint_bytes     = Keypair.decode_base58(currency_mint)
      vault_pda,    _ = vault_state_pda
      op_rev,       _ = op_rev_ata_pda(currency_mint)
      treasury_ata  = Keypair.decode_base58(treasury_ata_pubkey)

      data = Transaction.anchor_discriminator("sweep_operator_revenue") +
             Borsh.encode_u64(amount.to_i)

      serialized = build_partial_signed(
        accounts: [
          { pubkey: Keypair.admin.public_key_bytes, is_signer: true,  is_writable: true  },
          { pubkey: cosigner_bytes,                 is_signer: true,  is_writable: false },
          { pubkey: vault_pda,                      is_signer: false, is_writable: false },
          { pubkey: mint_bytes,                     is_signer: false, is_writable: false },
          { pubkey: op_rev,                         is_signer: false, is_writable: true  },
          { pubkey: treasury_ata,                   is_signer: false, is_writable: true  },
          { pubkey: Transaction::TOKEN_PROGRAM_ID,  is_signer: false, is_writable: false }
        ],
        data: data,
        additional_signers: [cosigner_bytes]
      )
      { serialized_tx: serialized }
    end

    # --- Contest read (v0.16 borsh layout) ---
    #
    # Contest v0.16 fields (in order):
    #   contest_id [u8;32], admin Pubkey, creator Pubkey, season_id u32,
    #   prize_pool u64,
    #   entry_fee_by_currency [u64;16]   (128 bytes),
    #   entry_fees [u64;16]              (128 bytes),
    #   max_entries u32, current_entries u32,
    #   status (u8 enum: 0=Open 1=Locked 2=Settled 3=Cancelled),
    #   payout_amounts Vec<u64>(max 10),
    #   bump u8, lock_timestamp i64 (v0.17), conclusion_timestamp i64 (v0.18),
    #   _reserved [u8;16]
    def read_contest(contest_slug, commitment: "confirmed")
      pda, _ = contest_pda(contest_slug)
      pda_base58 = Keypair.encode_base58(pda)

      info = client.get_account_info(pda_base58, commitment: commitment)
      return nil unless info&.dig("value")

      data = Base64.decode64(info["value"]["data"][0])
      offset = 8 # skip Anchor discriminator

      _contest_id,        offset = Borsh.decode_pubkey(data, offset)
      admin_bytes,        offset = Borsh.decode_pubkey(data, offset)
      creator_bytes,      offset = Borsh.decode_pubkey(data, offset)
      season_id,          offset = Borsh.decode_u32(data, offset)
      prize_pool,         offset = Borsh.decode_u64(data, offset)

      entry_fee_by_currency = []
      16.times do
        v, offset = Borsh.decode_u64(data, offset)
        entry_fee_by_currency << v
      end
      entry_fees = []
      16.times do
        v, offset = Borsh.decode_u64(data, offset)
        entry_fees << v
      end

      max_entries,        offset = Borsh.decode_u32(data, offset)
      current_entries,    offset = Borsh.decode_u32(data, offset)
      status_byte,        offset = Borsh.decode_u8(data, offset)
      vec_len,            offset = Borsh.decode_u32(data, offset)
      payout_amounts = vec_len.times.map { v, offset = Borsh.decode_u64(data, offset); v }

      # v0.17: bump (u8) then the derived lock_timestamp (i64, Unix seconds;
      # 0 = no lock). decode_u64 is exact for non-negative i64 (timestamps are
      # always >= 0 and < 2^63); solana-studio 0.4.3 ships no decode_i64.
      _bump,              offset = Borsh.decode_u8(data, offset)
      lock_ts,            offset = Borsh.decode_u64(data, offset)
      # v0.18: conclusion_timestamp i64 (Unix seconds; 0 = none). decode_u64 is
      # exact for non-negative i64 (same rationale as lock_ts above).
      conclusion_ts,      offset = Borsh.decode_u64(data, offset)

      status_name = %w[Open Locked Settled Cancelled][status_byte] || "Unknown"

      total_fees_collected = entry_fees.sum

      {
        pda:                   pda_base58,
        admin:                 Keypair.encode_base58(admin_bytes),
        creator:               Keypair.encode_base58(creator_bytes),
        season_id:             season_id,
        prize_pool:            prize_pool,
        prize_pool_dollars:    Config.lamports_to_dollars(prize_pool),
        entry_fee_by_currency: entry_fee_by_currency,
        entry_fees:            entry_fees,
        entry_fees_dollars:    entry_fees.map { |c| Config.lamports_to_dollars(c) },
        total_entry_fees_collected:         total_fees_collected,
        total_entry_fees_collected_dollars: Config.lamports_to_dollars(total_fees_collected),
        max_entries:           max_entries,
        current_entries:       current_entries,
        status:                status_name,
        lock_timestamp:        lock_ts,
        locks_at:              (lock_ts.zero? ? nil : Time.at(lock_ts).utc),
        conclusion_timestamp:  conclusion_ts,
        concludes_at:          (conclusion_ts.zero? ? nil : Time.at(conclusion_ts).utc),
        payout_amounts:        payout_amounts.map { |a| Config.lamports_to_dollars(a) },
        # Back-compat keys (v0.15.1 shape). USDC-only world had a single
        # entry_fee scalar — surface slot 0 (USDC) here so existing callers
        # don't need to learn about the array yet.
        entry_fee:             entry_fee_by_currency[0],
        entry_fee_dollars:     Config.lamports_to_dollars(entry_fee_by_currency[0]),
        prizes:                prize_pool,
        prizes_dollars:        Config.lamports_to_dollars(prize_pool)
      }
    end

    # ── Entry tokens (turf-vault v0.9.0+) ───────────────────────────────────
    # On-chain EntryTokenAccount PDAs per token. Source enum: 0=operator, 1=stripe, 2=moonpay.

    # paypal (3), coinflow (4) and aeropay (5) are Rails-side only for now — the
    # deployed program stores the source byte unvalidated (turf-vault
    # mint_entry_token.rs assigns it raw), so no program upgrade is needed;
    # mirror them into state.rs's entry_token_source mod on the next turf-vault
    # release. A rail whose purchase_type has no entry here KeyErrors at mint
    # (mint_entry_token does ENTRY_TOKEN_SOURCE.fetch(source)) — see
    # test/services/solana/entry_token_pda_test.rb.
    ENTRY_TOKEN_SOURCE = { operator: 0, stripe: 1, moonpay: 2, paypal: 3, coinflow: 4, aeropay: 5 }.freeze
    ENTRY_TOKEN_LEN = 124 # bytes — 8 disc + 32 owner + 1 source + 64 source_ref + 1 consumed + 9 consumed_at + 8 created_at + 1 bump

    def mint_entry_token(wallet_address:, source:, source_ref:)
      source_u8 = source.is_a?(Symbol) ? ENTRY_TOKEN_SOURCE.fetch(source) : source.to_i

      admin = Keypair.admin
      wallet_bytes = Keypair.decode_base58(wallet_address)

      # v0.19 (#9): the PDA is seeded on sha256(source_ref) and the program
      # asserts the passed `source_ref_hash` equals it. `source_ref` must be
      # GLOBALLY unique across wallets — re-minting the same ref collides on
      # init (true idempotency; safe for Sidekiq retries). `sequence` is gone.
      ref_buffer = padded_source_ref(source_ref)        # the exact [u8;64] the program hashes
      ref_hash   = Digest::SHA256.digest(ref_buffer)    # [u8;32] — seed + asserted arg
      pda, _ = Transaction.find_pda([b("entry_token"), ref_hash], @program_id)

      data = Transaction.anchor_discriminator("mint_entry_token") +
             [source_u8].pack("C") +   # source: u8
             ref_buffer +              # source_ref: [u8;64] (fixed array — raw bytes)
             ref_hash                  # source_ref_hash: [u8;32] (fixed array — raw bytes)

      vault_pda, _ = vault_state_pda

      tx = build_tx(admin)
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: admin.public_key_bytes,         is_signer: true,  is_writable: true  }, # admin
          { pubkey: vault_pda,                      is_signer: false, is_writable: false }, # vault_state
          { pubkey: wallet_bytes,                   is_signer: false, is_writable: false }, # user_wallet
          { pubkey: pda,                            is_signer: false, is_writable: true  }, # entry_token (init)
          { pubkey: Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false }
        ],
        data: data
      )

      signature = client.send_and_confirm(tx.serialize_base64)
      invalidate_entry_tokens_cache(wallet_address)
      { signature: signature, pda: Keypair.encode_base58(pda) }
    end

    # Admin-signed standalone seed grant (Rails "quest" bonuses). 1-of-3 vault
    # signer. Credits a fixed `amount` of loyalty seeds into a user's UserAccount
    # OUTSIDE the entry flow — first username change, newsletter join, friend-
    # invite-entered. The user does NOT sign (admin credits on their behalf, the
    # same trust model as settle_contest mutating arbitrary UserAccounts).
    #
    # Idempotent ON-CHAIN: the [b"seed_grant", wallet, kind, invitee] guard PDA
    # is init-once, so a repeat grant of the same (user, kind[, invitee]) collides
    # on init (custom program error 0x0) and raises — the real double-grant guard,
    # safe even if a Rails-side flag misfires.
    #   - :username / :newsletter → invitee MUST be nil (once-EVER per user)
    #   - :invite                 → invitee = the friend's wallet (once-per-invitee)
    #
    # Returns { signature:, pda:, seeds_earned:, seeds_total:, seeds_level: } so a
    # controller can splat a StateFanout('seeds') payload with no second RPC derive.
    #
    # NOTE: requires the user's on-chain UserAccount PDA to already exist (it's
    # loaded, not init'd). Username-first-change implies it; for a brand-new
    # account call ensure_user_account first.
    def grant_seeds(wallet_address:, amount:, kind:, invitee: nil)
      kind_u8 = kind.is_a?(Symbol) ? SEED_GRANT_KIND.fetch(kind) : kind.to_i
      amount  = amount.to_i
      unless amount.between?(1, 1_000)
        raise ArgumentError, "seed grant amount must be 1..1000 (got #{amount})"
      end
      if kind_u8 == SEED_GRANT_KIND[:invite]
        raise ArgumentError, "invitee required for :invite grants" if invitee.nil?
      elsif !invitee.nil?
        raise ArgumentError, "invitee must be nil for :#{kind} grants"
      end

      admin         = Keypair.admin
      wallet_bytes  = Keypair.decode_base58(wallet_address)
      invitee_bytes = invitee ? Keypair.decode_base58(invitee) : ("\x00".b * 32)

      user_pda,  _ = user_account_pda(wallet_address)
      vault_pda, _ = vault_state_pda
      grant_pda, _ = Transaction.find_pda(
        [b("seed_grant"), wallet_bytes, [kind_u8].pack("C"), invitee_bytes], @program_id
      )

      data = Transaction.anchor_discriminator("grant_seeds") +
             Borsh.encode_u64(amount) +  # amount: u64
             [kind_u8].pack("C") +       # kind:   u8
             invitee_bytes               # invitee: Pubkey (32 raw bytes; zeros = default)

      signature = with_account_init_retry do
        tx = build_tx(admin)
        tx.add_instruction(
          program_id: @program_id,
          accounts: [
            { pubkey: admin.public_key_bytes,         is_signer: true,  is_writable: true  }, # admin
            { pubkey: vault_pda,                      is_signer: false, is_writable: false }, # vault_state
            { pubkey: wallet_bytes,                   is_signer: false, is_writable: false }, # user_wallet
            { pubkey: user_pda,                       is_signer: false, is_writable: true  }, # user_account
            { pubkey: grant_pda,                      is_signer: false, is_writable: true  }, # seed_grant (init)
            { pubkey: Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false }
          ],
          data: data
        )
        client.send_and_confirm(tx.serialize_base64)
      end

      onchain     = (sync_balance(wallet_address) rescue nil)
      seeds_total = onchain&.dig(:seeds).to_i

      {
        signature:    signature,
        pda:          Keypair.encode_base58(grant_pda),
        seeds_earned: amount,
        seeds_total:  seeds_total,
        seeds_level:  User.level_for(seeds_total)
      }
    end

    def list_entry_tokens(wallet_address, commitment: "confirmed")
      # race_condition_ttl bounds the thundering herd when the 60s entry-token
      # cache expires under concurrent hydrate calls: the first reader bumps the
      # expiry by this window while it regenerates, so the others serve the
      # still-warm list instead of all firing the getProgramAccounts scan. It
      # affects only PASSIVE 60s expiry — the write-time invalidation on
      # mint/consume (invalidate_entry_tokens_cache) DELETEs the key, which
      # race_condition_ttl does not touch, so a consumed token is never served
      # stale past a write. The cached list is display-only anyway: entry
      # funding re-derives tokens live and fails safe on-chain.
      Rails.cache.fetch(entry_tokens_cache_key(wallet_address), expires_in: 60.seconds, race_condition_ttl: 5.seconds) do
        owner_b58 = wallet_address
        program_id_b58 = Keypair.encode_base58(@program_id)
        result = client.send(:call, "getProgramAccounts", [
          program_id_b58,
          {
            encoding: "base64",
            commitment: commitment,
            filters: [
              { dataSize: ENTRY_TOKEN_LEN },
              { memcmp: { offset: 8, bytes: owner_b58 } }
            ]
          }
        ])
        (result || []).map { |account| decode_entry_token(account) }
      end
    end

    def invalidate_entry_tokens_cache(wallet_address)
      Rails.cache.delete(entry_tokens_cache_key(wallet_address))
    end

    # Class method so the navbar render path (ApplicationController) can build
    # the key WITHOUT allocating a Vault instance — and so it's a single source
    # of truth shared by the cache-first read (display_entry_token_count), the
    # warm-on-hydrate write (list_entry_tokens), and the mint/consume
    # invalidation (invalidate_entry_tokens_cache). Read-key ≡ write-key ≡
    # invalidate-key, by construction.
    def self.entry_tokens_cache_key(wallet_address)
      "entry_tokens:#{wallet_address}"
    end

    def entry_tokens_cache_key(wallet_address)
      self.class.entry_tokens_cache_key(wallet_address)
    end

    # ── Seasons (turf-vault v0.11.0+) ────────────────────────────────────────

    # v0.23 layout (229 bytes): 8 disc + 4 season_id + 32 name + 40 schedule
    # + 128 quest_seeds (u64 × 16) + 8 start_at + 8 created_at + 1 bump.
    # Grew by 128 from the pre-v0.23 101-byte layout when quest_seeds[16] landed.
    SEASON_LEN = 229
    SEASON_DEFAULT_SCHEDULE = [25, 19, 14, 10, 7].freeze

    # Per-quest-kind reward defaults (Season.quest_seeds, indexed by kind u8).
    # username/newsletter/chat = 25; invite (kind 2) = 50 so two referred friends
    # who enter a contest = 100 = a free entry (matches the share card copy).
    # Kinds 4–15 reserved = 0.
    QUEST_SEED_DEFAULTS = ([25, 25, 50, 25] + [0] * 12).freeze
    # Fallback per-quest reward when no Season is active / can't be read.
    QUEST_SEED_FALLBACK = 25

    def create_season(season_id:, name:, schedule:, quest_seeds: nil, start_at: nil)
      raise ArgumentError, "schedule must have 5 elements" unless schedule.is_a?(Array) && schedule.length == 5
      schedule.each { |v| raise ArgumentError, "schedule values must be non-negative" if v.to_i.negative? }

      quest_seeds ||= QUEST_SEED_DEFAULTS
      unless quest_seeds.is_a?(Array) && quest_seeds.length == 16
        raise ArgumentError, "quest_seeds must have 16 elements"
      end
      quest_seeds.each { |v| raise ArgumentError, "quest_seeds values must be non-negative integers" if !v.is_a?(Integer) || v.negative? }

      start_at ||= Time.current.to_i
      admin = Keypair.admin
      pda, _ = season_pda(season_id)
      vault_pda, _ = vault_state_pda

      name_bytes = name.to_s.b.bytes.first(32)
      name_bytes += [0] * (32 - name_bytes.length)

      data = Transaction.anchor_discriminator("create_season") +
             Borsh.encode_u32(season_id) +
             name_bytes.pack("C*") +
             schedule.map { |v| Borsh.encode_u64(v.to_i) }.join +
             quest_seeds.map { |v| Borsh.encode_u64(v.to_i) }.join +
             Borsh.encode_i64(start_at.to_i)

      tx = build_tx(admin)
      tx.add_instruction(
        program_id: @program_id,
        accounts: [
          { pubkey: admin.public_key_bytes, is_signer: true,  is_writable: true  },
          { pubkey: vault_pda,              is_signer: false, is_writable: false },
          { pubkey: pda,                    is_signer: false, is_writable: true  },
          { pubkey: Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false }
        ],
        data: data
      )

      signature = client.send_and_confirm(tx.serialize_base64)
      Rails.cache.delete("seasons:all")
      { signature: signature, pda: Keypair.encode_base58(pda), season_id: season_id }
    end

    def list_seasons(commitment: "confirmed")
      Rails.cache.fetch("seasons:all", expires_in: 60.seconds) do
        result = client.send(:call, "getProgramAccounts", [
          Keypair.encode_base58(@program_id),
          {
            encoding: "base64",
            commitment: commitment,
            filters: [{ dataSize: SEASON_LEN }]
          }
        ])
        (result || []).map { |account| decode_season(account) }.sort_by { |s| s[:season_id] }
      end
    end

    def get_season(season_id, commitment: "confirmed")
      pda, _ = season_pda(season_id)
      info = client.get_account_info(Keypair.encode_base58(pda), commitment: commitment)
      return nil unless info&.dig("value")
      decode_season({ "pubkey" => Keypair.encode_base58(pda), "account" => info["value"] })
    end

    def seeds_for_entry(entry_num, season_id: nil)
      season_id ||= SeasonConfig.current_season_id
      season = season_id.to_i.positive? ? (get_season(season_id) rescue nil) : nil
      schedule = season ? season[:seed_schedule] : SEASON_DEFAULT_SCHEDULE
      schedule[[entry_num.to_i, 4].min]
    end

    # Per-quest seed reward, sourced from the active Season's quest_seeds
    # (v0.23+), indexed by the grant kind (u8). `kind` accepts a Symbol
    # (:username/:newsletter/:invite/:chat) or the raw u8. Falls back to
    # QUEST_SEED_FALLBACK when no Season is active, the read fails, or the
    # configured per-kind reward is zero/missing — mirrors seeds_for_entry's
    # season-read/rescue style so a deferred grant still pays a sane amount.
    def seeds_for_quest(kind)
      kind_u8 = kind.is_a?(Symbol) ? SEED_GRANT_KIND.fetch(kind) : kind.to_i
      season_id = SeasonConfig.current_season_id
      season = season_id.to_i.positive? ? (get_season(season_id) rescue nil) : nil
      reward = season&.dig(:quest_seeds)&.[](kind_u8)
      reward.is_a?(Integer) && reward.positive? ? reward : QUEST_SEED_FALLBACK
    end

    # Connection-level transport failures Net::HTTP can raise that solana-studio's
    # Solana::Client does NOT already normalize to Solana::Client::RpcError. Its
    # #call wraps ONLY Net::OpenTimeout/Net::ReadTimeout/Errno::ECONNRESET
    # (solana-studio lib/solana/client.rb#call); a Helius connection refusal
    # (Errno::ECONNREFUSED), DNS failure (SocketError), TLS handshake error
    # (OpenSSL::SSL::SSLError), broken stream (IOError), or host-unreachable
    # (Errno::EHOSTUNREACH etc. — all SystemCallError) therefore escapes
    # get_balance UNWRAPPED. Left alone it walks straight past the funding-decision
    # callers' `rescue Solana::Client::RpcError` (ContestsController
    # #resolve_web2_entry_funding! / #entry_funding_status) → a false-block / 500
    # on the entry path while the documented fail-open never fires. We normalize
    # them to RpcError below so the caller contract holds for EVERY transport
    # failure. Deliberately NOT StandardError — a genuine bug (decode/NoMethod)
    # must still surface and, on the funding paths, fail CLOSED.
    #
    # UPSTREAM: the correct long-term home is solana-studio's Solana::Client#call
    # (extend the timeout rescue's exception list) so EVERY consumer benefits; this
    # vault-side normalization is defense-in-depth and stays a harmless no-op if the
    # gem is later hardened (the earlier `rescue Solana::Client::RpcError` catches
    # the wrapped error first). See task fix-vault-connection-error-escape.
    WALLET_READ_TRANSPORT_ERRORS = [
      SocketError,            # DNS resolution failure (getaddrinfo)
      SystemCallError,        # parent of every Errno:: (ECONNREFUSED, EHOSTUNREACH, ETIMEDOUT, EPIPE, ...)
      OpenSSL::SSL::SSLError, # TLS handshake / certificate failure
      IOError                 # broken / closed stream mid-read
    ].freeze

    # raise_on_read_error: when true, a balance-read RPC failure RE-RAISES
    # Solana::Client::RpcError instead of being swallowed to an empty/zero balance.
    # This lets a FUNDING-DECISION caller (ContestsController's entry pre-check /
    # #entry_funding_status) distinguish a transient read FAILURE from a confirmed
    # $0 wallet — both otherwise collapse to `usdc: 0` here (a fresh wallet with no
    # ATA AND a flaked read both yield no USDC entry in `tokens`), which would
    # FALSE-BLOCK a genuinely funded user during a flake (Avi review 2026-06-13).
    # The default (false) preserves the navbar-hydrate behavior: a transient flake
    # just renders a stale/zero pill, never an error. Both RPC reads (get_balance
    # AND get_token_accounts_by_owner) share one rescue so a connection-level fault
    # on EITHER read routes through the same contract — previously get_balance sat
    # outside any rescue, so a connection failure there escaped entirely.
    def fetch_wallet_balances(wallet_address, raise_on_read_error: false)
      sol_balance = 0.0
      tokens = {}

      begin
        sol_result = client.get_balance(wallet_address)
        sol_lamports = sol_result.is_a?(Hash) ? sol_result["value"] : sol_result
        sol_balance = sol_lamports.to_f / 1_000_000_000

        result = client.get_token_accounts_by_owner(wallet_address)
        if result && result["value"]
          result["value"].each do |account|
            parsed = account.dig("account", "data", "parsed", "info")
            next unless parsed
            mint = parsed["mint"]
            amount = parsed.dig("tokenAmount", "uiAmount") || 0
            tokens[mint] = amount
          end
        end
      rescue Solana::Client::RpcError
        raise if raise_on_read_error
      rescue *WALLET_READ_TRANSPORT_ERRORS => e
        # A connection-level failure the gem left UNWRAPPED. Normalize to the
        # RpcError the funding-decision callers already rescue so the fail-open
        # fires instead of a 500 / false-block; the default (navbar) path still
        # collapses to a stale/zero pill, never an error.
        raise Solana::Client::RpcError.new("Network error: #{e.class}: #{e.message}") if raise_on_read_error
      end

      {
        sol: sol_balance,
        usdc: Config::USDC_MINT.present? ? (tokens[Config::USDC_MINT] || 0) : nil,
        usdt: Config::USDT_MINT.present? ? (tokens[Config::USDT_MINT] || 0) : nil,
        tokens: tokens
      }
    end

    # Raised by #assert_entry_cosign_safe! when the Phantom-signed wire tx the
    # client POSTs to confirm_onchain_entry is NOT the enter_contest we prepared
    # (audit C1 — admin blind-cosign). The admin keypair must NEVER blind-sign
    # arbitrary client bytes: a crafted SystemProgram.transfer{from: admin},
    # mint_entry_token, grant_seeds, etc. would otherwise be admin-cosigned and
    # broadcast. The message carries a DETAILED reason for server logs only — the
    # controller maps it to a generic client message (never leak which check tripped).
    class UnsafeCosignError < StandardError; end

    # Position of the contest_entry (entry PDA) account inside the enter_contest
    # instruction's account list — see #enter_contest_accounts: 0 payer, 1 user,
    # 2 user_account, 3 vault_state, 4 contest, 5 contest_entry.
    ENTER_CONTEST_ENTRY_PDA_POSITION = 5

    # SystemInstruction::AdvanceNonceAccount discriminant (u32 LE 4). The ONLY
    # System instruction permitted in a cosignable entry — see SystemProgram
    # .advance_nonce_account in solana-studio.
    SYSTEM_ADVANCE_NONCE_DATA = [4].pack("V").freeze

    # SEMANTIC allowlist validation of a Phantom-signed entry wire BEFORE the
    # admin cosigns it (audit C1). The client round-trips the tx through web3.js
    # (Transaction.from(...).serialize()), so the returned message bytes may be
    # RE-ENCODED — byte-equality with the stored serialized_tx would reject legit
    # entries. Instead we DECODE the wire and assert it is exactly the
    # enter_contest we built:
    #
    #   1. Fee payer (account[0]) == the admin managed wallet. Admin is the only
    #      signature slot the server fills; if admin isn't the fee payer there is
    #      nothing legitimate to cosign. The strict instruction allowlist below
    #      means admin can never be the writable destination of a value transfer
    #      (every System transfer is rejected; enter_contest debits the USER).
    #   2. EXACTLY ONE turf-vault instruction, and it must be `enter_contest`
    #      (discriminator match — rejects mint_entry_token / settle_contest / any
    #      other instruction on our PROGRAM_ID). Its contest_entry account must
    #      equal the server-derived entry_pda(contest, wallet, entry_num) for THIS
    #      entry (defense-in-depth; mirrors verify_and_confirm_onchain_entry!).
    #   3. System Program: ONLY advanceNonceAccount (data == u32 LE 4), and only
    #      when a durable nonce is configured AND the advance targets the
    #      configured SOLANA_DURABLE_NONCE_PUBKEY. A System transfer (opcode 2) or
    #      anything else → reject. (Durable nonce is LIVE on mainnet — every real
    #      entry that anchors on it carries this ix; omitting it here would break
    #      every production entry.)
    #   4. ComputeBudget: allowed (priority-fee / CU-limit hints; no authority risk).
    #   5. Any other program id or instruction → reject.
    #
    # Raises UnsafeCosignError (logged server-side via #cosign_reject!) on the
    # first failure. Returns true when the wire is safe to cosign + broadcast.
    def assert_entry_cosign_safe!(signed_wire_base64, entry:, wallet_address:)
      cosign_reject!(entry, wallet_address, "empty_wire: no signed_tx bytes") if signed_wire_base64.blank?

      msg =
        begin
          parse_wire_message(Base64.decode64(signed_wire_base64).b, entry: entry, wallet_address: wallet_address)
        rescue UnsafeCosignError
          raise
        rescue StandardError => e
          cosign_reject!(entry, wallet_address, "unparseable_wire: #{e.class}: #{e.message}")
        end
      account_keys = msg[:account_keys]

      admin_key = Keypair.admin.public_key_bytes.b

      # (1) Fee payer (account[0]) must be the admin managed wallet.
      fee_payer = account_keys[0]
      if fee_payer != admin_key
        cosign_reject!(entry, wallet_address,
          "fee_payer_not_admin: account[0]=#{b58(fee_payer)} expected admin=#{Keypair.admin.address}")
      end

      # Server-derive the enter_contest binding for THIS entry (never trust the wire).
      entry_num = entry.entry_number
      if entry_num.nil?
        cosign_reject!(entry, wallet_address, "no_entry_number: entry ##{entry.id} has no entry_number to bind")
      end
      expected_entry_pda = entry_pda(entry.contest.slug, wallet_address, entry_num).first.b

      enter_disc       = Transaction.anchor_discriminator("enter_contest").b
      turf_vault       = @program_id.b
      system_program   = Transaction::SYSTEM_PROGRAM_ID.b   # 32 zero bytes
      compute_budget   = COMPUTE_BUDGET_PROGRAM_ID.b
      lighthouse       = LIGHTHOUSE_PROGRAM_ID.b
      dn               = durable_nonce_config
      configured_nonce = dn && Keypair.decode_base58(dn.fetch(:pubkey)).b

      enter_count = 0

      msg[:instructions].each_with_index do |ix, i|
        program_id = account_keys[ix[:program_id_index]]
        cosign_reject!(entry, wallet_address, "bad_program_index: ix #{i} program index out of range") if program_id.nil?
        program_id = program_id.b

        case program_id
        when turf_vault
          # (2) Only enter_contest, bound to THIS entry's PDA.
          unless ix[:data].byteslice(0, 8) == enter_disc
            cosign_reject!(entry, wallet_address,
              "wrong_turf_vault_ix: ix #{i} disc=#{ix[:data].byteslice(0, 8).to_s.unpack1('H*')} != enter_contest")
          end
          enter_count += 1
          slot = ix[:account_indices][ENTER_CONTEST_ENTRY_PDA_POSITION]
          ix_entry_pda = slot && account_keys[slot]
          if ix_entry_pda != expected_entry_pda
            cosign_reject!(entry, wallet_address,
              "entry_pda_mismatch: ix #{i} entry account=#{b58(ix_entry_pda)} expected=#{b58(expected_entry_pda)}")
          end
        when system_program
          # (3) Only the durable-nonce advance, targeting the configured nonce.
          unless ix[:data] == SYSTEM_ADVANCE_NONCE_DATA
            cosign_reject!(entry, wallet_address,
              "system_not_advance: ix #{i} data=#{ix[:data].to_s.unpack1('H*')} (only advanceNonceAccount allowed)")
          end
          if configured_nonce.nil?
            cosign_reject!(entry, wallet_address, "advance_without_config: advanceNonceAccount but no durable nonce configured")
          end
          nonce_slot = ix[:account_indices][0]
          nonce_acct = nonce_slot && account_keys[nonce_slot]
          if nonce_acct != configured_nonce
            cosign_reject!(entry, wallet_address,
              "wrong_nonce_account: ix #{i} nonce=#{b58(nonce_acct)} expected=#{dn.fetch(:pubkey)}")
          end
        when compute_budget
          # (4) Priority-fee / CU-limit hints — allowed, carry no authority risk.
        when lighthouse
          # (5) Phantom-injected Lighthouse protection assertions — allowed.
          # Pure post-state asserts (the worst they can do is fail the tx);
          # they cannot transfer funds or grant authority, so they pose no
          # risk to the admin cosign. See LIGHTHOUSE_PROGRAM_ID.
        else
          # (6) Anything else — reject.
          cosign_reject!(entry, wallet_address, "disallowed_program: ix #{i} program=#{b58(program_id)}")
        end
      end

      unless enter_count == 1
        cosign_reject!(entry, wallet_address, "enter_contest_count: found #{enter_count} enter_contest ixs, require exactly 1")
      end

      true
    end

    # Same admin blind-cosign boundary as #assert_entry_cosign_safe!, but for
    # contest creation. The form payload is signed server-side into
    # params_token; the browser only returns Phantom-signed wire bytes. Before
    # filling the admin signature slot, assert that the wire still contains
    # exactly the create_contest instruction for that token's slug, creator,
    # fee schedule, max entries, payouts, prize pool, and lock timestamp.
    def assert_create_contest_cosign_safe!(signed_wire_base64, wallet_address:, contest_slug:, onchain_params:)
      context = "create_contest:#{contest_slug}"
      cosign_reject!(context, wallet_address, "empty_wire: no signed_tx bytes") if signed_wire_base64.blank?

      spec = create_contest_instruction(wallet_address, contest_slug, **onchain_params.symbolize_keys)
      expected_accounts = spec[:accounts].map { |meta| meta[:pubkey].b }
      expected_data = spec[:data].b

      msg =
        begin
          parse_wire_message(Base64.decode64(signed_wire_base64).b, entry: context, wallet_address: wallet_address)
        rescue UnsafeCosignError
          raise
        rescue StandardError => e
          cosign_reject!(context, wallet_address, "unparseable_wire: #{e.class}: #{e.message}")
        end
      account_keys = msg[:account_keys]

      admin_key = Keypair.admin.public_key_bytes.b
      fee_payer = account_keys[0]
      if fee_payer != admin_key
        cosign_reject!(context, wallet_address,
          "fee_payer_not_admin: account[0]=#{b58(fee_payer)} expected admin=#{Keypair.admin.address}")
      end

      create_disc      = Transaction.anchor_discriminator("create_contest").b
      turf_vault       = @program_id.b
      system_program   = Transaction::SYSTEM_PROGRAM_ID.b
      compute_budget   = COMPUTE_BUDGET_PROGRAM_ID.b
      lighthouse       = LIGHTHOUSE_PROGRAM_ID.b
      dn               = durable_nonce_config
      configured_nonce = dn && Keypair.decode_base58(dn.fetch(:pubkey)).b

      create_count = 0

      msg[:instructions].each_with_index do |ix, i|
        program_id = account_keys[ix[:program_id_index]]
        cosign_reject!(context, wallet_address, "bad_program_index: ix #{i} program index out of range") if program_id.nil?
        program_id = program_id.b

        case program_id
        when turf_vault
          unless ix[:data].byteslice(0, 8) == create_disc
            cosign_reject!(context, wallet_address,
              "wrong_turf_vault_ix: ix #{i} disc=#{ix[:data].byteslice(0, 8).to_s.unpack1('H*')} != create_contest")
          end
          unless ix[:data] == expected_data
            cosign_reject!(context, wallet_address, "create_data_mismatch: ix #{i} does not match server payload")
          end
          actual_accounts = ix[:account_indices].map { |idx| account_keys[idx]&.b }
          unless actual_accounts == expected_accounts
            cosign_reject!(context, wallet_address,
              "create_accounts_mismatch: ix #{i} accounts=#{actual_accounts.map { |a| b58(a) }.join(',')}")
          end
          create_count += 1
        when system_program
          unless ix[:data] == SYSTEM_ADVANCE_NONCE_DATA
            cosign_reject!(context, wallet_address,
              "system_not_advance: ix #{i} data=#{ix[:data].to_s.unpack1('H*')} (only advanceNonceAccount allowed)")
          end
          if configured_nonce.nil?
            cosign_reject!(context, wallet_address, "advance_without_config: advanceNonceAccount but no durable nonce configured")
          end
          nonce_slot = ix[:account_indices][0]
          nonce_acct = nonce_slot && account_keys[nonce_slot]
          if nonce_acct != configured_nonce
            cosign_reject!(context, wallet_address,
              "wrong_nonce_account: ix #{i} nonce=#{b58(nonce_acct)} expected=#{dn.fetch(:pubkey)}")
          end
        when compute_budget
          # Priority-fee / CU-limit hints — allowed, carry no authority risk.
        when lighthouse
          # Phantom-injected transaction-protection assertions — allowed.
        else
          cosign_reject!(context, wallet_address, "disallowed_program: ix #{i} program=#{b58(program_id)}")
        end
      end

      unless create_count == 1
        cosign_reject!(context, wallet_address, "create_contest_count: found #{create_count} create_contest ixs, require exactly 1")
      end

      true
    end

    # Cosign (admin) the Phantom-signed entry wire, pre-flight simulate, then
    # broadcast. Public API called by ContestsController#confirm_onchain_entry.
    # The caller MUST run #assert_entry_cosign_safe! first (audit C1) — this
    # method fills the admin signature slot over WHATEVER bytes it is handed.
    def cosign_and_broadcast_entry(signed_wire_base64)
      patched_b64 = Transaction.cosign_wire_base64(signed_wire_base64, signer: Keypair.admin)

      # Server-side pre-flight. sig_verify:false — both sigs are present now but we
      # don't need the RPC to re-verify; we want program-error + log surfacing.
      # replace_recent_blockhash:true — entry txs are anchored on the DURABLE
      # NONCE when SOLANA_DURABLE_NONCE_PUBKEY is set (prod is), and a nonce
      # value is never in the recent-blockhash queue, so a default simulation
      # rejects every nonce-anchored tx with "BlockhashNotFound" (prod,
      # 2026-06-11; devnet has no nonce configured, so staging never saw it).
      # The RPC requires sigVerify=false alongside replaceRecentBlockhash —
      # already our setting; the real broadcast still enforces signatures.
      sim = client.simulate_transaction(patched_b64, sig_verify: false,
                                        replace_recent_blockhash: true)
      if sim && sim["err"]
        logs = Array(sim["logs"]).last(6).join("\n")
        raise "Entry pre-flight simulation failed: #{sim['err'].inspect}#{logs.empty? ? '' : "\n#{logs}"}"
      end

      client.send_and_confirm(patched_b64)
    end

    def cosign_and_broadcast_create_contest(signed_wire_base64)
      patched_b64 = Transaction.cosign_wire_base64(signed_wire_base64, signer: Keypair.admin)

      sim = client.simulate_transaction(patched_b64, sig_verify: false,
                                        replace_recent_blockhash: true)
      if sim && sim["err"]
        logs = Array(sim["logs"]).last(6).join("\n")
        raise "Contest-create pre-flight simulation failed: #{sim['err'].inspect}#{logs.empty? ? '' : "\n#{logs}"}"
      end

      client.send_and_confirm(patched_b64)
    end

    private

    # Decode a LEGACY (unversioned) Solana wire transaction into its account keys
    # and instructions, for #assert_entry_cosign_safe!. Mirrors the header/account
    # walk in Solana::Transaction.cosign_wire and reuses its public read_compact_u16
    # primitive. Every malformed/oversized read raises (→ converted to
    # UnsafeCosignError by the caller) so a truncated or crafted payload fails
    # CLOSED. A versioned (v0+) message — high bit set on numRequiredSignatures —
    # is rejected: this legacy parser can't safely walk address-table lookups, and
    # the entry build emits + Phantom round-trips a legacy message, so a v0 here is
    # anomalous.
    #
    # Returns { account_keys: [<32-byte String>, ...],
    #           instructions: [{ program_id_index:, account_indices: [Int], data: String }, ...] }.
    def parse_wire_message(wire, entry:, wallet_address:)
      cursor = 0
      sig_count, cursor = Transaction.read_compact_u16(wire, cursor)
      cosign_reject!(entry, wallet_address, "no_signatures: zero signature slots") if sig_count.zero?
      message_start = cursor + (sig_count * 64)
      cosign_reject!(entry, wallet_address, "truncated_sigs: wire shorter than declared signatures") if wire.bytesize < message_start + 4

      first = wire.getbyte(message_start)
      cosign_reject!(entry, wallet_address, "versioned_message: v0+ tx not supported") if (first & 0x80) != 0

      c = message_start + 3 # skip the 3-byte message header (numReqSigs, roSigned, roUnsigned)
      account_count, c = Transaction.read_compact_u16(wire, c)
      account_keys = []
      account_count.times do
        cosign_reject!(entry, wallet_address, "truncated_account_keys") if wire.bytesize < c + 32
        account_keys << wire.byteslice(c, 32)
        c += 32
      end
      c += 32 # recent blockhash / durable nonce value
      cosign_reject!(entry, wallet_address, "truncated_blockhash") if c > wire.bytesize

      ix_count, c = Transaction.read_compact_u16(wire, c)
      instructions = []
      ix_count.times do
        program_id_index = wire.getbyte(c)
        cosign_reject!(entry, wallet_address, "truncated_ix_header") if program_id_index.nil?
        c += 1
        accounts_len, c = Transaction.read_compact_u16(wire, c)
        account_indices = []
        accounts_len.times do
          idx = wire.getbyte(c)
          cosign_reject!(entry, wallet_address, "truncated_ix_accounts") if idx.nil?
          account_indices << idx
          c += 1
        end
        data_len, c = Transaction.read_compact_u16(wire, c)
        cosign_reject!(entry, wallet_address, "truncated_ix_data") if wire.bytesize < c + data_len
        data = wire.byteslice(c, data_len) || "".b
        c += data_len
        instructions << { program_id_index: program_id_index, account_indices: account_indices, data: data }
      end

      { account_keys: account_keys, instructions: instructions }
    end

    # Log the DETAILED rejection reason server-side (forensics: entry id + wallet
    # + which check failed) and raise the typed error. The controller maps
    # UnsafeCosignError to a generic client message — the reason here is NEVER
    # returned to the client.
    def cosign_reject!(entry, wallet_address, reason)
      entry_id = entry.respond_to?(:id) ? entry.id : entry.inspect
      Rails.logger.warn("[cosign][rejected] entry_id=#{entry_id} wallet=#{wallet_address} reason=#{reason}")
      raise UnsafeCosignError, reason
    end

    # Short base58 for log lines; nil-safe.
    def b58(bytes)
      bytes.nil? ? "nil" : Keypair.encode_base58(bytes)
    end

    # Pad/truncate a fee array to 16 elements (MAX_CURRENCIES). Accepts:
    #   - Array of u64 lamport amounts (e.g. [1_900_000, 0, 0, ...])
    #   - Hash of currency_idx => amount (e.g. { 0 => 1_900_000 })
    def pad_fee_array(fees)
      arr = Array.new(16, 0)
      if fees.is_a?(Hash)
        fees.each { |idx, amt| arr[idx.to_i] = amt.to_i }
      else
        Array(fees).each_with_index { |amt, idx| arr[idx] = amt.to_i }
      end
      arr
    end

    def mint_for_currency_idx(idx)
      case idx.to_i
      when 0 then Config::USDC_MINT
      when 1 then Config::USDT_MINT
      else
        # Slots 2-15 require an on-chain lookup via read_vault_state. Keep the
        # service interface honest and bail loudly until the UI surfaces
        # currency choice (Phase 2).
        state = read_vault_state
        slot = state&.dig(:accepted_currencies)&.dig(idx.to_i)
        raise "Unknown currency_idx #{idx} — slot empty or vault unread" unless slot && slot[:mint] != ZERO_PUBKEY_B58
        slot[:mint]
      end
    end

    # Account list for enter_contest. Shared between the server-signed
    # (managed wallet) and partial-signed (Phantom) builders.
    def enter_contest_accounts(payer_bytes:, user_bytes:, user_pda:, vault_pda:, contest_pda:,
                               entry_pda:, currency_mint:, user_token_account:, op_rev_ata:,
                               season_pda:)
      [
        { pubkey: payer_bytes,                    is_signer: true,  is_writable: true  }, # payer
        { pubkey: user_bytes,                     is_signer: true,  is_writable: true  }, # user
        { pubkey: user_pda,                       is_signer: false, is_writable: true  }, # user_account
        { pubkey: vault_pda,                      is_signer: false, is_writable: false }, # vault_state
        { pubkey: contest_pda,                    is_signer: false, is_writable: true  }, # contest
        { pubkey: entry_pda,                      is_signer: false, is_writable: true  }, # contest_entry (init)
        { pubkey: currency_mint,                  is_signer: false, is_writable: false }, # currency_mint
        { pubkey: user_token_account,             is_signer: false, is_writable: true  }, # user_token_account
        { pubkey: op_rev_ata,                     is_signer: false, is_writable: true  }, # op_rev_ata
        { pubkey: season_pda,                     is_signer: false, is_writable: false }, # season
        { pubkey: Transaction::TOKEN_PROGRAM_ID,  is_signer: false, is_writable: false },
        { pubkey: Transaction::SYSTEM_PROGRAM_ID, is_signer: false, is_writable: false }
      ]
    end

    # remaining_accounts for settle: triples per winner [user_account_pda,
    # contest_entry_pda, winner_usdc_ata]. v0.16 added the USDC ATA so the
    # SPL CPI can pay each winner directly.
    def settle_remaining_accounts(contest_slug, settlements)
      settlements.flat_map do |s|
        user_pda, _   = user_account_pda(s[:wallet])
        e_pda,    _   = entry_pda(contest_slug, s[:wallet], s[:entry_num])
        winner_ata, _ = Solana::SplToken.find_associated_token_address(s[:wallet], Config::USDC_MINT)
        [
          { pubkey: user_pda,   is_signer: false, is_writable: true },
          { pubkey: e_pda,      is_signer: false, is_writable: true },
          { pubkey: winner_ata, is_signer: false, is_writable: true }
        ]
      end
    end

    # ComputeBudgetInstruction::set_compute_unit_limit. Discriminator = 0x02,
    # followed by a little-endian u32 of the requested CU limit.
    def compute_unit_limit_ix(units)
      data = "\x02".b + [units].pack("V")
      {
        program_id: COMPUTE_BUDGET_PROGRAM_ID,
        accounts: [],
        data: data
      }
    end

    # ComputeBudgetInstruction::set_compute_unit_price. Discriminator = 0x03,
    # followed by a little-endian u64 of µlamports-per-CU. This is the
    # instruction create_contest lacked — it sets the priority fee the leader
    # uses to order the TX. Fee paid = price × CU limit.
    def compute_unit_price_ix(micro_lamports)
      data = "\x03".b + [micro_lamports].pack("Q<")
      {
        program_id: COMPUTE_BUDGET_PROGRAM_ID,
        accounts: [],
        data: data
      }
    end

    # Fetch the user's USDC ATA balance in lamports. Returns 0 if the ATA
    # doesn't exist (user hasn't been funded yet).
    def fetch_usdc_ata_balance_lamports(wallet_address)
      ata_bytes, _ = Solana::SplToken.find_associated_token_address(wallet_address, Config::USDC_MINT)
      ata_base58 = Keypair.encode_base58(ata_bytes)
      info = client.get_token_account_balance(ata_base58) rescue nil
      amount = info&.dig("value", "amount")
      amount ? amount.to_i : 0
    rescue StandardError
      0
    end

    # When `durable_nonce` ({ pubkey:, authority: }) is given, anchor the tx on
    # the nonce instead of a recent blockhash: set recentBlockhash = the stored
    # nonce and prepend SystemProgram.advanceNonceAccount as instruction #0. The
    # tx then NEVER expires until it lands — immune to slow signing (the mainnet
    # BlockhashNotFound incident). The authority signs the advance; it's the admin
    # managed wallet, which is already `signer` here, so no extra signature.
    def build_tx(signer, durable_nonce: nil)
      tx = Transaction.new
      if durable_nonce
        tx.set_recent_blockhash(fetch_nonce_value(durable_nonce.fetch(:pubkey)))
        tx.add_signer(signer)
        adv = Solana::SystemProgram.advance_nonce_account(
          nonce: durable_nonce.fetch(:pubkey), authority: durable_nonce.fetch(:authority)
        )
        tx.add_instruction(program_id: adv[:program_id], accounts: adv[:accounts], data: adv[:data])
      else
        tx.set_recent_blockhash(client.get_latest_blockhash)
        tx.add_signer(signer)
      end
      tx
    end

    def build_partial_signed(accounts:, data:, additional_signers:, durable_nonce: nil)
      tx = build_tx(Keypair.admin, durable_nonce: durable_nonce)
      # ComputeBudget ixs (priority fee + CU cap) give the TX a non-zero priority
      # fee so a mainnet leader picks it up under load — the fix for the fee-less
      # create_contest drops. When a durable nonce is set, build_tx already
      # prepended advanceNonceAccount as ix #0; these follow it (still valid —
      # only the advance has to be first).
      tx.add_instruction(**compute_unit_price_ix(PARTIAL_TX_PRIORITY_FEE_MICROLAMPORTS))
      tx.add_instruction(**compute_unit_limit_ix(PARTIAL_TX_COMPUTE_UNIT_LIMIT))
      tx.add_instruction(program_id: @program_id, accounts: accounts, data: data)
      tx.serialize_partial_base64(additional_signers: additional_signers)
    end

    # Phantom-FIRST variant of build_partial_signed: builds a FULLY-UNSIGNED tx
    # (no local @signers) — every required signature slot is left empty for
    # external signers. The admin (fee payer + nonce authority) is passed as an
    # ADDITIONAL signer so its slot is reserved but NOT filled here; the server
    # fills it later via Transaction.cosign_wire AFTER Phantom signs.
    #
    # Why: when the server pre-signs and Phantom signs second, Phantom's
    # Lighthouse heuristics flag the multi-signer ordering ("could be malicious").
    # Flipping the order — Phantom signs the unsigned tx first, server cosigns
    # second — clears that rule. The server can't rebuild-and-resign after Phantom
    # (that changes the message bytes and breaks Phantom's sig), so it must build
    # the tx unsigned and surgically patch the admin slot in afterwards.
    #
    # `additional_signers` MUST list the admin FIRST (fee payer ordering) followed
    # by the user/Phantom wallet. The advanceNonceAccount ix (when a durable nonce
    # is set) still names the admin as authority — the gem's keyless build leaves
    # that slot empty too, and cosign_wire fills it with the admin signature.
    def build_partial_unsigned(accounts:, data:, additional_signers:, durable_nonce: nil)
      tx = build_tx_unsigned(durable_nonce: durable_nonce)
      tx.add_instruction(**compute_unit_price_ix(PARTIAL_TX_PRIORITY_FEE_MICROLAMPORTS))
      tx.add_instruction(**compute_unit_limit_ix(PARTIAL_TX_COMPUTE_UNIT_LIMIT))
      tx.add_instruction(program_id: @program_id, accounts: accounts, data: data)
      tx.serialize_partial_base64(additional_signers: additional_signers)
    end

    # Like build_tx but adds NO local signer — used for the Phantom-first build.
    # The fee payer must be supplied as the first additional_signer at serialize
    # time (the gem's keyless serialize_partial uses additional_signers.first as
    # the fee payer when @signers is empty).
    def build_tx_unsigned(durable_nonce: nil)
      tx = Transaction.new
      if durable_nonce
        tx.set_recent_blockhash(fetch_nonce_value(durable_nonce.fetch(:pubkey)))
        adv = Solana::SystemProgram.advance_nonce_account(
          nonce: durable_nonce.fetch(:pubkey), authority: durable_nonce.fetch(:authority)
        )
        tx.add_instruction(program_id: adv[:program_id], accounts: adv[:accounts], data: adv[:data])
      else
        tx.set_recent_blockhash(client.get_latest_blockhash)
      end
      tx
    end

    # Opt-in durable-nonce config — set SOLANA_DURABLE_NONCE_PUBKEY to make
    # operator flows anchor on it; authority is the admin managed wallet (already
    # cosigns server-side). Returns nil (= default recent-blockhash) when unset.
    def durable_nonce_config
      pubkey = ENV["SOLANA_DURABLE_NONCE_PUBKEY"].presence or return nil
      { pubkey: pubkey, authority: Keypair.admin.address }
    end

    # Read + verify the stored nonce value off a nonce account.
    def fetch_nonce_value(pubkey)
      result = client.get_account_info(pubkey)
      b64 = result&.dig("value", "data", 0) or raise "durable nonce account #{pubkey} not found"
      na = Solana::NonceAccount.parse(Base64.decode64(b64).b)
      raise "durable nonce account #{pubkey} is not initialized" unless na.initialized?
      na.nonce
    end

    def with_account_init_retry(attempts: 4)
      tries = 0
      begin
        tries += 1
        yield
      rescue => e
        msg = e.message.to_s
        transient = msg.include?("0xbc4") || msg.include?("AccountNotInitialized")
        raise unless transient && tries < attempts
        sleep(tries * 2)
        retry
      end
    end

    # The cluster's "transaction signature" = the FIRST signature on the wire
    # (the fee payer's): compact-u16 signature count, then 64-byte sigs.
    def extract_tx_signature(wire)
      _count, offset = Transaction.read_compact_u16(wire, 0)
      sig = wire.byteslice(offset, 64)
      raise "wire too short to carry a signature" if sig.nil? || sig.bytesize != 64
      Keypair.encode_base58(sig)
    end

    def b(str)
      str.b
    end

    def username_bytes32(username)
      bytes = username.to_s.b.bytes.first(32)
      bytes += [0] * (32 - bytes.length)
      bytes.pack("C*")
    end

    def decode_season(account)
      data = Base64.decode64(account.dig("account", "data", 0))
      if data.bytesize < SEASON_LEN
        raise "Season account #{account['pubkey']} has #{data.bytesize} bytes; expected #{SEASON_LEN}"
      end

      offset = 8
      season_id, offset = Borsh.decode_u32(data, offset)
      name_bytes = data[offset, 32]; offset += 32
      name = name_bytes.bytes.take_while { |b| b != 0 }.pack("C*").force_encoding("UTF-8")
      schedule = []
      5.times do
        v, offset = Borsh.decode_u64(data, offset)
        schedule << v
      end
      # v0.23: quest_seeds: [u64; 16] sits between schedule and start_at.
      quest_seeds = []
      16.times do
        v, offset = Borsh.decode_u64(data, offset)
        quest_seeds << v
      end
      start_at, offset = Borsh.decode_u64(data, offset)
      created_at, offset = Borsh.decode_u64(data, offset)
      {
        pda: account["pubkey"],
        season_id: season_id,
        name: name,
        seed_schedule: schedule,
        quest_seeds: quest_seeds,
        start_at: start_at,
        created_at: created_at
      }
    end

    def decode_entry_token(account)
      data = Base64.decode64(account.dig("account", "data", 0))
      offset = 8
      owner_bytes, offset = Borsh.decode_pubkey(data, offset)
      source = data[offset].ord; offset += 1
      ref_slice = data[offset, 64]; offset += 64
      source_ref = ref_slice.bytes.take_while { |b| b != 0 }.pack("C*").force_encoding("UTF-8")
      consumed = data[offset].ord == 1; offset += 1
      consumed_at_tag = data[offset].ord; offset += 1
      consumed_at_value, _ = Borsh.decode_u64(data, offset)
      consumed_at = consumed_at_tag == 1 ? consumed_at_value : nil
      offset += 8
      created_at, offset = Borsh.decode_u64(data, offset)
      {
        pda: account["pubkey"],
        owner: Keypair.encode_base58(owner_bytes),
        source: source,
        source_ref: source_ref,
        consumed: consumed,
        consumed_at: consumed_at,
        created_at: created_at
      }
    end
  end
end
