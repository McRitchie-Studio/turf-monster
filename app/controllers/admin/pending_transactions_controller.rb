module Admin
  class PendingTransactionsController < ApplicationController
    before_action :require_admin
    before_action :set_pending_transaction, only: [:show, :confirm, :rebuild, :broadcast]

    def index
      @pending = PendingTransaction.order(created_at: :desc)
      @pending_count = PendingTransaction.pending.count
      # The named cosigner slot every builder reserves, and the wallets that
      # may fill an EXTRA slot: the vault's signer set minus the server's admin
      # key and minus the named cosigner, both of which are already spent.
      # Rendered on the page so the operator picks before the blockhash clock
      # starts — the slots are part of the message and cannot be added once the
      # first wallet has signed.
      @primary_cosigner = Solana::Config::MULTISIG_COSIGNER
      @eligible_extras  = Solana::CosignPlan.eligible_cosigners - [@primary_cosigner]

      # THE ACCOUNT THAT ACTUALLY PAYS, read ONCE for the page.
      #
      # Not per row: it is an RPC round trip and every row has the same fee
      # payer. Not at all when nothing on the page needs signing — an admin
      # opening an empty queue should not spend a network call to be told about
      # an account he is not about to use.
      #
      # It NEVER blocks the page. `#fee_payer_status` rescues to
      # `funded: nil` (read failed), which the roster renders as "could not
      # read" rather than as empty — refusing to let the operator act on a
      # transient RPC flake would be its own outage.
      @fee_payer = if @pending.any? { |tx| tx.pending? && tx.extra_cosigners_needed.positive? }
        Solana::Vault.new.fee_payer_status(required_signatures: 3)
      end
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
        # The out-of-band path records the same full signer set the in-app path
        # does. An operator who broadcast elsewhere still signed with three
        # wallets on a three-signature action, and a row that names one of them
        # is a worse audit answer than no row at all.
        extras = require_extra_cosigners!(primary: cosigner)
        verify_and_record_cosign!(cosigner: cosigner, extras: extras,
                                  signature: params[:tx_signature])

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
        extras   = require_extra_cosigners!(primary: cosigner)
        signed_tx = params[:signed_tx].to_s
        raise "Signed transaction required" if signed_tx.blank?

        # Raises with the PROGRAM's own error + logs when the simulation fails,
        # and never reaches the chain in that case.
        signature = Solana::Vault.new.simulate_and_broadcast(signed_tx)

        verify_and_record_cosign!(cosigner: cosigner, extras: extras, signature: signature)

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

        # THE THIRD SIGNATURE'S SLOT IS RESERVED HERE OR NOWHERE. turf-vault
        # v0.26 raised six of these actions to three signatures, and
        # `authorize` fills the gap from the LEADING `remaining_accounts` —
        # accounts that are part of the message, so they cannot be added after
        # the operator has signed without invalidating that signature. A
        # rebuild that omits them produces a transaction that is already short
        # before Phantom is opened.
        plan   = Solana::CosignPlan.new(tx_type: @tx.tx_type)
        extras = plan.validate_extras!(params[:extra_cosigners], primary: cosigner)

        result =
          case @tx.tx_type
          when "settle_contest"
            settlements = meta["settlements"].map(&:symbolize_keys)
            vault.build_settle_contest(@tx.target.slug, settlements, cosigner_pubkey: cosigner,
                                                                     extra_cosigners: extras)
          when "cancel_contest"
            vault.build_cancel_contest(@tx.target.slug, creator_pubkey: meta["creator"],
                                                        cosigner_pubkey: cosigner,
                                                        extra_cosigners: extras)
          when "register_currency"
            vault.build_register_currency(cosigner_pubkey: cosigner, mint: meta["mint"],
                                          kind: meta["kind"].to_i, extra_cosigners: extras)
          when "deactivate_currency"
            vault.build_deactivate_currency(cosigner_pubkey: cosigner,
                                            currency_idx: meta["currency_idx"].to_i,
                                            extra_cosigners: extras)
          when "sweep_operator_revenue"
            mint = meta["currency_mint"]
            vault.build_sweep_operator_revenue(
              cosigner_pubkey: cosigner,
              currency_mint: mint,
              treasury_ata_pubkey: vault.treasury_ata_for(mint),
              amount: meta["amount"].to_i,
              extra_cosigners: extras
            )
          else
            raise "Unsupported tx_type for rebuild: #{@tx.tx_type}"
          end

        @tx.update!(serialized_tx: result[:serialized_tx], status: "pending")

        respond_to do |format|
          format.json do
            render json: {
              status: "rebuilt",
              serialized_tx: result[:serialized_tx],
              # The signing plan travels WITH the bytes it describes, so the
              # browser collects against the slots this very build reserved
              # rather than against whatever the page was rendered believing.
              required_signatures: plan.required_signatures,
              cosigner_address: cosigner,
              extra_cosigners: extras,
              # The slot that is ALREADY filled. The server signed as admin when
              # this transaction was built, so the roster can mark that row done
              # before the operator touches Phantom — without it, a
              # three-signature action shows two rows to act on and the count
              # looks wrong at the one moment he is counting.
              fee_payer_address: Solana::CosignPlan.admin_address
            }
          end
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

    # The EXTRA cosigners a broadcast claims signed, validated the same way the
    # rebuild validated them.
    #
    # RE-VALIDATED RATHER THAN TRUSTED FROM THE REBUILD. The two requests are
    # separate round trips and nothing binds them: a broadcast can name a
    # different set from the one whose slots were reserved. Re-running the same
    # plan means a mismatch is refused here, by a sentence naming the action,
    # instead of being recorded as fact about who authorised a payout.
    #
    # It does NOT re-prove the signatures — `simulate_and_broadcast` and the
    # chain do that. What it protects is the RECORD: `verify_and_record_cosign!`
    # writes these addresses onto the row as the audit answer to "who signed
    # this", and an unvalidated address would make that answer unreliable in
    # exactly the case an audit is opened.
    def require_extra_cosigners!(primary:)
      Solana::CosignPlan.new(tx_type: @tx.tx_type)
                        .validate_extras!(params[:extra_cosigners], primary: primary)
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
    def verify_and_record_cosign!(cosigner:, signature:, extras: [])
      Solana::TxVerifier.verify!(
        signature: signature,
        instruction_name: instruction_for_tx_type(@tx.tx_type),
        signer_pubkey: cosigner,
        writable_pubkey: writable_for_target(@tx)
      )

      # EVERY extra cosigner is asserted to be in a SIGNER SLOT of the landed
      # transaction, not merely present in it. That distinction is the whole
      # defect this change closes: turf-vault reads the leading
      # `remaining_accounts` as cosigners and requires `info.is_signer` on each,
      # and `settle_contest` failed 6047 CosignerDidNotSign precisely because a
      # non-signer payload account was sitting in a slot a signer should hold.
      # A transaction that landed proves the chain was satisfied; this proves
      # the row we are about to write names the signers that satisfied it.
      Array(extras).each do |extra|
        Solana::TxVerifier.verify!(
          signature: signature,
          instruction_name: instruction_for_tx_type(@tx.tx_type),
          signer_pubkey: extra,
          writable_pubkey: nil
        )
      end

      @tx.update!(status: "confirmed", cosigner_address: cosigner,
                  cosigner_addresses: [cosigner, *Array(extras)], tx_signature: signature)

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
