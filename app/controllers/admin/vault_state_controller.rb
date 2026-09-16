module Admin
  # Vault pause / unpause admin UI (M5, v0.15.0).
  #
  # turf-vault's `pause` / `unpause` instructions require 2-of-3 multisig.
  # The bot signs server-side as `admin`; the cosigner slot is left empty
  # for a Phantom wallet (Alex or Mason) to fill via the same direct-cosign
  # pattern the Vault Init UI uses (see VaultInitController).
  #
  # Pause is an EMERGENCY action — designed for rapid response when a bug
  # or attack is detected. Don't gate it behind the PendingTransaction
  # queue; the cosigner needs to be present and ready, not async.
  class VaultStateController < ApplicationController
    before_action :require_admin

    # Default cosigner shown in the form. Configurable via env in case the
    # active operator is Mason (or whoever's on call). Matches the existing
    # Treasury cosign default (Solana::Config::MULTISIG_COSIGNER = Alex).
    def show
      @vault          = Solana::Vault.new.read_vault_state
      # BROWSER-facing (rendered into #cosign-config for web3.js), so the
      # public endpoint — RPC_URL carries the provider api-key on mainnet.
      @rpc_url        = Solana::Config.public_rpc_url
      @network        = Solana::Config::NETWORK
      @default_cosigner = Solana::Config::MULTISIG_COSIGNER
      @multisig_signers = Solana::Config::MULTISIG_SIGNERS
      # `pause` and `unpause` no longer need the same number of signatures, so
      # the page renders a plan per action rather than one cosigner control.
      @unpause_plan     = Solana::CosignPlan.new(tx_type: "unpause")
      @eligible_extras  = Solana::CosignPlan.eligible_cosigners - [@default_cosigner]
    end

    # Build a partially-signed `pause` TX. Validates the cosigner is a
    # known multisig signer + a reason is supplied (reason is logged
    # on-chain for incident triage).
    def pause
      rescue_and_log do
        vault = Solana::Vault.new
        state = vault.read_vault_state
        raise "Vault not initialized" unless state
        raise "Vault is already paused" if state[:paused]

        cosigner = params[:cosigner_pubkey].to_s.strip
        reason   = params[:reason].to_s.strip
        validate_cosigner!(cosigner)
        raise "Reason is required (logged on-chain for triage)" if reason.blank?
        raise "Reason must be ≤ 64 bytes" if reason.bytesize > 64

        result = vault.build_pause_vault(cosigner_pubkey: cosigner, reason: reason)
        render json: result.merge(cosigner_pubkey: cosigner, instruction: "pause")
      end
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # Build a partially-signed `unpause` TX.
    def unpause
      rescue_and_log do
        vault = Solana::Vault.new
        state = vault.read_vault_state
        raise "Vault not initialized" unless state
        raise "Vault is already unpaused" unless state[:paused]

        cosigner = params[:cosigner_pubkey].to_s.strip
        validate_cosigner!(cosigner)

        # UNPAUSE IS FLOORED AT THREE and is the one path here that rose.
        # `pause` stays at two on purpose — the brake must be easier to pull
        # than the attack it stops — so the two actions on this page now need
        # different numbers of signatures and only this one reserves an extra
        # slot. Lifting the brake is deliberately harder than pulling it: no
        # agent-reachable pair can release its own pause.
        plan   = Solana::CosignPlan.new(tx_type: "unpause")
        extras = plan.validate_extras!(params[:extra_cosigners], primary: cosigner)

        result = vault.build_unpause_vault(cosigner_pubkey: cosigner, extra_cosigners: extras)
        render json: result.merge(cosigner_pubkey: cosigner, instruction: "unpause",
                                  required_signatures: plan.required_signatures,
                                  extra_cosigners: extras)
      end
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # Verify the on-chain TX after Phantom submits. Asserts:
    #   - instruction matches what the client claims (pause or unpause)
    #   - cosigner is present as a signer
    #   - VaultState PDA is writable in the TX
    def confirm
      rescue_and_log do
        cosigner    = params[:cosigner_pubkey].to_s.strip
        tx_sig      = params[:tx_signature].to_s.strip
        instruction = params[:instruction].to_s.strip
        raise "cosigner_pubkey required" if cosigner.blank?
        raise "tx_signature required"    if tx_sig.blank?
        raise "Unsupported instruction"  unless %w[pause unpause].include?(instruction)

        vault_pda_b58 = Solana::Keypair.encode_base58(Solana::Vault.new.vault_state_pda.first)

        Solana::TxVerifier.verify!(
          signature: tx_sig,
          instruction_name: instruction,
          signer_pubkey: cosigner,
          writable_pubkey: vault_pda_b58
        )

        # Every extra cosigner must be in a SIGNER SLOT of what landed, not
        # merely named by the request. `unpause` is floored at three, so a
        # confirmation that proves one signature proves a third of the claim.
        Array(params[:extra_cosigners]).each do |extra|
          next if extra.to_s.strip.blank?

          validate_cosigner!(extra.to_s.strip)
          Solana::TxVerifier.verify!(
            signature: tx_sig,
            instruction_name: instruction,
            signer_pubkey: extra.to_s.strip,
            writable_pubkey: nil
          )
        end

        # Bust the navbar badge cache so the 🚨 indicator flips immediately.
        Rails.cache.delete(self.class.paused_cache_key)

        render json: { status: "ok", tx_signature: tx_sig, vault_pda: vault_pda_b58 }
      end
    rescue Solana::TxVerifier::VerificationError, StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # Navbar badge check — shares a single VaultState read with
    # Admin::VaultInitController.vault_uninitialized? via
    # Solana::Vault.cached_vault_state (memoized on Current per request).
    def self.vault_paused?
      Solana::Vault.cached_vault_state&.dig(:paused) || false
    rescue StandardError
      false # never block the navbar render on an RPC blip
    end

    def self.paused_cache_key
      "vault_state:paused:#{Solana::Config::PROGRAM_ID}"
    end

    private

    def validate_cosigner!(cosigner)
      raise "cosigner_pubkey required" if cosigner.blank?
      raise "Invalid pubkey: #{cosigner}" unless valid_base58_pubkey?(cosigner)
      raise "Cosigner not in multisig set" unless Solana::Config::MULTISIG_SIGNERS.include?(cosigner)
    end

    def valid_base58_pubkey?(str)
      Solana::Keypair.decode_base58(str).bytesize == 32
    rescue StandardError
      false
    end
  end
end
