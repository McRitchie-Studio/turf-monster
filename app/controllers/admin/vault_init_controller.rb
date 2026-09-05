module Admin
  # One-time vault-initialize UI. The on-chain `initialize` instruction is
  # gated to `INIT_AUTHORITY` on mainnet builds — a Phantom keypair the
  # server intentionally does not hold. This controller builds a partially-
  # signed TX (admin bot pays fees), hands it to the browser for Phantom to
  # cosign, then verifies the resulting on-chain TX.
  class VaultInitController < ApplicationController
    before_action :require_admin

    # Delegate to Solana::Config so the hardcoded values live in exactly one
    # place. INIT_AUTHORITY mirrors `state.rs::INIT_AUTHORITY`; the signer
    # set + threshold mirror what `initialize` writes into VaultState.
    INIT_AUTHORITY     = Solana::Config::INIT_AUTHORITY
    DEFAULT_SIGNERS    = Solana::Config::MULTISIG_SIGNERS
    DEFAULT_THRESHOLD  = Solana::Config::MULTISIG_THRESHOLD
    # v0.16: treasury_authority is pinned at initialize time so leaked admin
    # keys can't drain swept operator revenue to anywhere but the Squads
    # vault. Each cluster runs its OWN Squad, so this address differs per
    # cluster — devnet BW13…H6kC, mainnet Bk9s…GdJm.
    #
    # WHAT THIS REPLACES (vault-pda-readers-diverge). The default used to be
    # `ENV.fetch("SOLANA_SQUADS_VAULT_PDA", "<devnet literal>")`, which carried
    # two defects in one expression:
    #   1. The fallback was NOT network-keyed, so a mainnet build with the
    #      variable unset offered the DEVNET Squad as the treasury authority.
    #   2. `ENV.fetch` only takes its default when the key is ABSENT — a key
    #      present but empty yields "", so the fallback never ran at all.
    #      `heroku config:set VAR=` sets exactly that empty string, and that is
    #      the live state of both deployed apps (verified 2026-09-05:
    #      SOLANA_SQUADS_VAULT_PDA is length 0 on turf-monster-mainnet AND
    #      turf-monster-qa). So this form offered a BLANK treasury on both.
    #
    # A METHOD rather than a constant, for the reason
    # `Solana::Config.squads_vault_pda` is one: the value derives from NETWORK,
    # and freezing it at class-load time is what makes a per-cluster reader
    # untestable without constant surgery. The resolution itself lives in
    # Solana::Config — env wins via `.presence`, only the DEFAULT is
    # network-keyed — so this file holds no address of its own.
    def self.default_treasury_authority
      Solana::Config.squads_vault_pda
    end

    def show
      @vault = Solana::Vault.new.read_vault_state
      @init_authority = INIT_AUTHORITY
      @default_signers = DEFAULT_SIGNERS
      @default_threshold = DEFAULT_THRESHOLD
      @default_treasury_authority = self.class.default_treasury_authority
      # BROWSER-facing (rendered into #cosign-config for web3.js), so the
      # public endpoint — RPC_URL carries the provider api-key on mainnet.
      @rpc_url = Solana::Config.public_rpc_url
      @network = Solana::Config::NETWORK
    end

    def build
      rescue_and_log do
        raise "Vault already initialized" if Solana::Vault.new.read_vault_state

        creator   = params[:creator_pubkey].to_s.strip
        signers   = [params[:signer_1], params[:signer_2], params[:signer_3]].map { |s| s.to_s.strip }
        threshold = params[:threshold].to_i
        treasury  = params[:treasury_authority].presence&.strip || self.class.default_treasury_authority

        validate_init_params!(creator, signers, threshold, treasury)

        result = Solana::Vault.new.build_initialize_vault(
          creator_pubkey:     creator,
          signers:            signers,
          threshold:          threshold,
          treasury_authority: treasury
        )

        render json: result.merge(creator_pubkey: creator, treasury_authority: treasury)
      end
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    def confirm
      rescue_and_log do
        creator       = params[:creator_pubkey].to_s.strip
        tx_signature  = params[:tx_signature].to_s.strip
        raise "creator_pubkey required" if creator.blank?
        raise "tx_signature required"   if tx_signature.blank?

        vault_pda_b58 = Solana::Keypair.encode_base58(Solana::Vault.new.vault_state_pda.first)

        Solana::TxVerifier.verify!(
          signature: tx_signature,
          instruction_name: "initialize",
          signer_pubkey: creator,
          writable_pubkey: vault_pda_b58
        )

        Rails.cache.delete(self.class.uninitialized_cache_key)

        render json: { status: "ok", tx_signature: tx_signature, vault_pda: vault_pda_b58 }
      end
    rescue Solana::TxVerifier::VerificationError => e
      render json: { error: e.message }, status: :unprocessable_entity
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # Navbar badge check — answers "is the vault uninitialized?" off the
    # per-request shared VaultState read (Solana::Vault.cached_vault_state),
    # so this and the paused? check below cost one RPC together instead of
    # two. Rails.cache layer remains for cross-request reuse in prod;
    # Current-level memo carries dev where :null_store would otherwise let
    # every render through to Solana.
    #
    # Fails safe to false when the RPC errored (Current.vault_state_error)
    # so a transient blip doesn't pop the alarming "Vault Init" navbar/admin
    # affordance.
    def self.vault_uninitialized?
      state = Solana::Vault.cached_vault_state
      return false if Current.vault_state_error
      state.nil?
    rescue StandardError
      false # never block the navbar render on an RPC blip
    end

    def self.uninitialized_cache_key
      "vault_init:uninitialized:#{Solana::Config::PROGRAM_ID}"
    end

    private

    def validate_init_params!(creator, signers, threshold, treasury)
      raise "creator_pubkey required" if creator.blank?
      raise "Three signer addresses required" if signers.any?(&:blank?)
      raise "treasury_authority required" if treasury.blank?

      # Validate base58 BEFORE distinctness — three identical garbage strings
      # should report the invalid pubkey, not "must be distinct".
      ([creator, treasury] + signers).each do |pk|
        raise "Invalid pubkey: #{pk}" unless valid_base58_pubkey?(pk)
      end

      raise "Signers must be distinct" if signers.uniq.length != 3
      raise "Threshold must be 1, 2, or 3" unless (1..3).cover?(threshold)
      raise "creator_pubkey must be one of the signers" unless signers.include?(creator)

      # On mainnet the on-chain `initialize` will reject any creator that
      # isn't INIT_AUTHORITY — check up front so the user sees a clear
      # error before the TX round-trips.
      if Solana::Config.mainnet? && creator != INIT_AUTHORITY
        raise "creator_pubkey must equal INIT_AUTHORITY (#{INIT_AUTHORITY}) on mainnet"
      end
    end

    def valid_base58_pubkey?(str)
      Solana::Keypair.decode_base58(str).bytesize == 32
    rescue StandardError
      false
    end
  end
end
