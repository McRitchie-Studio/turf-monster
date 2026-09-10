module Admin
  class PendingTransactionsController < ApplicationController
    before_action :require_admin
    before_action :set_pending_transaction, only: [:show, :confirm, :rebuild, :broadcast]

    def index
      @pending = PendingTransaction.order(created_at: :desc)
      @pending_count = PendingTransaction.pending.count
    end

    def show
    end

    def confirm
      rescue_and_log(target: @tx) do
        raise "Transaction is #{@tx.status}, not pending" unless @tx.pending?

        # OPSEC-010 / OPSEC-011: semantic-verify the on-chain TX before
        # flipping DB state. Previously this endpoint accepted any string
        # as tx_signature and marked a contest settled without checking
        # what (if anything) actually landed on-chain. Now we:
        #   1. Confirm cosigner is in the multisig signer set
        #   2. Resolve the instruction + writable PDA from tx_type/target
        #   3. Assert the on-chain TX matches all of (program, instruction,
        #      cosigner-as-signer, target PDA writable)
        cosigner = require_multisig_cosigner!
        verify_and_record_cosign!(cosigner: cosigner, signature: params[:tx_signature])

        respond_to do |format|
          format.json { render json: { status: "confirmed", tx_signature: @tx.tx_signature } }
          format.html { redirect_to admin_pending_transactions_path, notice: "Transaction confirmed." }
        end
      end
    rescue Solana::TxVerifier::VerificationError => e
      respond_to do |format|
        format.json { render json: { error: e.message }, status: :unprocessable_entity }
        format.html { redirect_to admin_pending_transactions_path, alert: "Verification failed: #{e.message}" }
      end
    rescue StandardError => e
      respond_to do |format|
        format.json { render json: { error: e.message }, status: :unprocessable_entity }
        format.html { redirect_to admin_pending_transactions_path, alert: "Confirmation failed: #{e.message}" }
      end
    end

    # Broadcast the cosigned wire SERVER-SIDE, then run the same OPSEC-010/011
    # verification #confirm does and flip the DB state.
    #
    # The browser used to call connection.sendRawTransaction itself and then
    # POST the resulting signature to #confirm. That failed on mainnet every
    # single time (see Solana::Vault#simulate_and_broadcast for the three
    # compounding causes) and the failure was reported to the operator as a
    # blockhash guess, so a program error was indistinguishable from a
    # throttled RPC. $140 of alpha-contest payouts sat unsent from June to
    # September as a result.
    #
    # #confirm stays for the signature-first path (an operator who broadcast
    # out-of-band still has a signature to record); this action is what the
    # cosign page uses.
    def broadcast
      rescue_and_log(target: @tx) do
        raise "Transaction is #{@tx.status}, not pending" unless @tx.pending?

        cosigner = require_multisig_cosigner!
        signed_tx = params[:signed_tx].to_s
        raise "Signed transaction required" if signed_tx.blank?

        # Raises with the PROGRAM's own error + logs when the simulation fails,
        # and never reaches the chain in that case.
        signature = Solana::Vault.new.simulate_and_broadcast(signed_tx)

        verify_and_record_cosign!(cosigner: cosigner, signature: signature)

        render json: { status: "confirmed", tx_signature: signature }
      end
    rescue Solana::TxVerifier::VerificationError => e
      render json: { error: "Verification failed: #{e.message}" }, status: :unprocessable_entity
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    def rebuild
      rescue_and_log(target: @tx) do
        raise "Transaction is #{@tx.status}, cannot rebuild" unless @tx.pending?

        vault    = Solana::Vault.new
        cosigner = Solana::Config::MULTISIG_COSIGNER
        meta     = JSON.parse(@tx.metadata)

        result =
          case @tx.tx_type
          when "settle_contest"
            settlements = meta["settlements"].map(&:symbolize_keys)
            vault.build_settle_contest(@tx.target.slug, settlements, cosigner_pubkey: cosigner)
          when "cancel_contest"
            vault.build_cancel_contest(@tx.target.slug, creator_pubkey: meta["creator"], cosigner_pubkey: cosigner)
          when "register_currency"
            vault.build_register_currency(cosigner_pubkey: cosigner, mint: meta["mint"], kind: meta["kind"].to_i)
          when "deactivate_currency"
            vault.build_deactivate_currency(cosigner_pubkey: cosigner, currency_idx: meta["currency_idx"].to_i)
          when "sweep_operator_revenue"
            mint = meta["currency_mint"]
            vault.build_sweep_operator_revenue(
              cosigner_pubkey: cosigner,
              currency_mint: mint,
              treasury_ata_pubkey: vault.treasury_ata_for(mint),
              amount: meta["amount"].to_i
            )
          else
            raise "Unsupported tx_type for rebuild: #{@tx.tx_type}"
          end

        @tx.update!(serialized_tx: result[:serialized_tx], status: "pending")

        respond_to do |format|
          format.json { render json: { status: "rebuilt", serialized_tx: result[:serialized_tx] } }
          format.html { redirect_to admin_pending_transactions_path, notice: "Transaction rebuilt with fresh blockhash." }
        end
      end
    rescue StandardError => e
      respond_to do |format|
        format.json { render json: { error: e.message }, status: :unprocessable_entity }
        format.html { redirect_to admin_pending_transactions_path, alert: "Rebuild failed: #{e.message}" }
      end
    end

    private

    def set_pending_transaction
      @tx = PendingTransaction.find_by(slug: params[:slug])
      return redirect_to admin_pending_transactions_path, alert: "Transaction not found" unless @tx
    end

    # OPSEC-010: the cosigner must be one of the vault's multisig signers before
    # anything is broadcast or recorded. Shared by #confirm and #broadcast.
    def require_multisig_cosigner!
      cosigner = params[:cosigner_address]
      raise "Cosigner address required" if cosigner.blank?
      raise "Cosigner not in multisig set" unless Solana::Config::MULTISIG_SIGNERS.include?(cosigner)

      cosigner
    end

    # OPSEC-010 / OPSEC-011: semantic-verify what actually landed on-chain, THEN
    # flip DB state. This endpoint used to accept any string as a tx_signature
    # and mark a contest settled without checking what (if anything) the chain
    # had seen. Verification asserts all of program, instruction,
    # cosigner-as-signer, and target PDA writable.
    #
    # Shared by #confirm (operator supplies the signature) and #broadcast (the
    # server just produced it) so the two paths can never drift on what they
    # verify or what they flip.
    def verify_and_record_cosign!(cosigner:, signature:)
      Solana::TxVerifier.verify!(
        signature: signature,
        instruction_name: instruction_for_tx_type(@tx.tx_type),
        signer_pubkey: cosigner,
        writable_pubkey: writable_for_target(@tx)
      )

      @tx.update!(status: "confirmed", cosigner_address: cosigner, tx_signature: signature)

      # settle/cancel both target a Contest; the currency/sweep types have no
      # Contest target and need no DB state change (the source of truth is the
      # on-chain VaultState / ATAs).
      case @tx.tx_type
      when "settle_contest"
        if @tx.target.is_a?(Contest)
          @tx.target.update!(onchain_settled: true)
          # The payout has now provably landed on-chain — only here do we tell
          # winners they won (never at grade time). Idempotent + skips
          # wallet-only winners; enqueues a background job per emailable winner.
          @tx.target.notify_winners!
        end
      when "cancel_contest"
        @tx.target.update!(onchain_cancelled: true) if @tx.target.is_a?(Contest)
      end
    end

    # Map PendingTransaction#tx_type → Anchor instruction name. The instruction
    # name equals the tx_type for every supported type today.
    def instruction_for_tx_type(tx_type)
      case tx_type
      when "settle_contest", "cancel_contest",
           "register_currency", "deactivate_currency", "sweep_operator_revenue"
        tx_type
      else
        raise "Unsupported tx_type for verification: #{tx_type}"
      end
    end

    # Resolve the writable PDA the TX is expected to mutate, per tx_type. Some
    # types carry no Contest target (the writable account lives in metadata), so
    # this takes the whole PendingTransaction. Returns nil for anything unknown;
    # TxVerifier.verify! then skips the writable assertion.
    def writable_for_target(tx)
      case tx.tx_type
      when "settle_contest", "cancel_contest"
        target = tx.target
        return nil unless target.is_a?(Contest)
        target.onchain_contest_id.presence ||
          Solana::Keypair.encode_base58(Solana::Vault.new.contest_pda(target.slug).first)
      when "register_currency", "deactivate_currency"
        # Both mutate the VaultState PDA (the accepted_currencies registry).
        Solana::Keypair.encode_base58(Solana::Vault.new.vault_state_pda.first)
      when "sweep_operator_revenue"
        # Mutates the op_rev ATA for the swept mint (the source of the transfer).
        mint = JSON.parse(tx.metadata)["currency_mint"]
        Solana::Keypair.encode_base58(Solana::Vault.new.op_rev_ata_pda(mint).first)
      else
        nil
      end
    end
  end
end
