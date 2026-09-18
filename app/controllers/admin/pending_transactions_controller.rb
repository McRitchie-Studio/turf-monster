module Admin
  class PendingTransactionsController < ApplicationController
    before_action :require_admin
    before_action :set_pending_transaction, only: [:show, :confirm, :rebuild, :broadcast, :reconcile]

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

    # Record a signature the operator already has — the signature-FIRST path.
    #
    # ── THIS PATH VERIFIES BEFORE IT RECORDS, AND MUST KEEP DOING SO ─────────
    #
    # The asymmetry with #broadcast is deliberate and is not a drift to tidy
    # away. There, the SERVER produced the signature and knows the wire left, so
    # recording it first is simply the truth. Here the signature is an
    # UNVERIFIED CLAIM from the client — OPSEC-010 exists because this endpoint
    # once accepted any string at all — and stamping it before verification
    # would let a caller pin an arbitrary signature onto a row and make it
    # un-broadcastable. Produced-by-us is recorded first; claimed-by-a-client is
    # proven first.
    #
    # ── IT IS ALSO THE RECONCILIATION DOOR ──────────────────────────────────
    #
    # It accepts a row that is `awaiting_reconciliation?` — one whose broadcast
    # was claimed and whose ANSWER was lost (an ambiguous RPC fault after the
    # send). That row must never be re-broadcast, but the operator who finds the
    # signature on chain has to be able to record it, and this is the only path
    # that can prove it before writing. Without this the double-send fix would
    # trade a loss of money for a permanently stuck treasury row.
    def confirm
      rescue_and_log(target: @tx) do
        unless @tx.pending? || @tx.awaiting_reconciliation?
          raise "Transaction is #{@tx.status}, not pending"
        end

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

    # Claim the row AND RECORD WHAT IS ABOUT TO GO OUT, broadcast the cosigned
    # wire SERVER-SIDE, then run the same OPSEC-010/011 verification #confirm
    # does and flip the DB state.
    #
    # ── THE SIGNATURE IS STAMPED BEFORE THE BROADCAST, NOT AFTER IT ──────────
    #
    # It does not come from the RPC at all. A transaction's signature is the
    # first 64 bytes of its own signed wire, so the server already holds it the
    # moment the operator hands the bytes over — `Solana::Vault#signature_for_wire`
    # reads it, and `PendingTransaction#claim_for_broadcast!` writes it in the
    # same conditional UPDATE that takes the claim.
    #
    # This path used to stamp it inside `verify_and_record_cosign!`, i.e. AFTER
    # `TxVerifier.verify!` had made one RPC call per claimed signer. A treasury
    # transaction that LANDED and then met an RPC hiccup during verification was
    # left `pending`, unsigned, and re-broadcastable: the money moved and the
    # record said it had not. A second click sent a second settle or a second
    # sweep, and only one of the two was ever reconciled.
    #
    # THE RULE, and it is general: never let a VERIFICATION step decide whether
    # a broadcast happened. The broadcast happened when the wire went out.
    # `Cdp::OfframpSendJob` persists its signature before the send for the same
    # reason, and `CdpRampTransaction#rearm_stalled_send!` double-sent a user's
    # USDC by breaking it. `Admin::AuthoritiesController#broadcast` is the
    # sibling of this action and holds the same claim/stamp/rewind shape — the
    # two must not drift, which is why all three live on the model.
    #
    # ── AND WHY "BEFORE" MATTERS MORE THAN "IMMEDIATELY" ─────────────────────
    #
    # Stamping from the RPC's reply — however fast — means a failure that eats
    # the reply leaves a claimed row with NO signature. Every door then shuts:
    # #rebuild and #broadcast refuse a non-pending row, #confirm needs a
    # signature that does not exist, and Admin::AuthoritiesController#cancel
    # refuses to discard something that may be on chain. That is a Rails
    # console, and it is the LIKELY outcome rather than a rare one, because the
    # node's own pre-flight rejects the real blockhash and the real signatures
    # that the simulation above deliberately does not check.
    #
    # With the signature stamped up front there is always a handle, so a failed
    # broadcast is answered by asking the chain — #reconcile — instead of by
    # reading an exception. A row left `submitted` is the SAFE failure: it names
    # its transaction, the guard below refuses a re-broadcast, and #reconcile
    # decides what actually happened to it.
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

        # EVERYTHING THAT CAN RAISE WITHOUT HAVING SENT ANYTHING HAPPENS ABOVE
        # THE CLAIM. `Solana::Vault.new` validates its RPC URL and decodes
        # keypairs in its constructor, so it can raise InsecureRpcUrlError or a
        # base58 error — neither of which is PreflightRejected, so neither
        # would give a claim back. Building it here costs nothing and takes the
        # whole class of constructor failures out of the claimed window.
        # Admin::AuthoritiesController#broadcast warms its vault before its own
        # claim for the same reason.
        vault = Solana::Vault.new

        # THE SIGNATURE IS A FACT ABOUT THE BYTES, not an answer from the RPC —
        # it is the first signature inside the wire the operator just signed.
        # Deriving it here, BEFORE the claim, does two things: a malformed wire
        # is refused without stranding a claim, and the claim below can record
        # what it is about to send in the same statement that takes it.
        signature = vault.signature_for_wire(signed_tx)

        # CLAIM THE ROW BEFORE THE WIRE GOES OUT. The `pending?` guard above is
        # a READ — two concurrent requests both pass it and both broadcast, and
        # because each rebuild mints fresh bytes the two carry different
        # signatures, so two settlements land. The claim is a single conditional
        # UPDATE; exactly one caller wins it. See
        # PendingTransaction#claim_for_broadcast! for why it is not `with_lock`.
        unless @tx.claim_for_broadcast!(signature)
          raise "This transaction is already being broadcast (it is now #{@tx.status}) — " \
                "reconcile it on chain rather than sending a second one."
        end

        # Raises with the PROGRAM's own error + logs when the simulation fails,
        # and never reaches the chain in that case.
        begin
          vault.simulate_and_broadcast(signed_tx)
        rescue Solana::Cosign::PreflightRejected
          # PROVABLY UN-SENT — the simulation refused it, or could not be run at
          # all, so `client.send_transaction` was never called. This is the ONLY
          # exception that rewinds the row, and the rewind names the signature
          # it is clearing so it cannot touch anything else. The gem's hierarchy
          # states the distinction in its own names: everything that MAY be on
          # chain is a `Cosign::BroadcastFailed`, which is deliberately NOT
          # rescued here — such a row keeps its claim and reconciles.
          #
          # A failure of the SEND does not rewind, however node-ish it looks.
          # Solana::Client#call retries internally on the faults that mean "the
          # request went out and the answer was lost", so a coded error can be
          # the SECOND answer to a wire the first attempt may already have
          # forwarded — the reasoning is written out on
          # Solana::Vault#simulate_and_broadcast. Such a row keeps its claim and
          # its signature, and #reconcile asks the chain instead of guessing.
          @tx.rewind_broadcast!(signature)
          raise
        end

        verify_and_record_cosign!(cosigner: cosigner, extras: extras, signature: signature)

        render json: { status: "confirmed", tx_signature: signature }
      end
    rescue Solana::TxVerifier::VerificationError => e
      render json: {
        error: "Broadcast landed but verification failed: #{e.message}. The signature is " \
               "recorded on this row and it will not be re-broadcast — reconcile it on chain " \
               "before acting again.",
        tx_signature: @tx.reload.tx_signature
      }, status: :unprocessable_entity
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # THE DOOR OUT OF A BROADCAST WHOSE ANSWER WE NEVER GOT.
    #
    # Asks the chain what happened to the signature this row already carries and
    # acts on the four-way verdict (PendingTransaction#reconcile_broadcast!).
    # It exists because NO exception raised by the broadcast can be read as a
    # proof that nothing was sent — Solana::Client#call retries the faults that
    # mean "the answer was lost" and hands the caller only the last one, so a
    # coded error may be the second reply to a wire the first attempt already
    # forwarded (Solana::Vault#simulate_and_broadcast writes it out). The chain
    # is the only witness, and this is where it is asked.
    #
    # It is also the ONLY path that can clear a transaction which LANDED AND
    # FAILED. #confirm cannot: Solana::TxVerifier refuses any transaction
    # carrying meta.err, which is correct for recording an authorisation and
    # useless for recording a definitive failure.
    #
    # A :landed row is NOT confirmed here. It still owes the OPSEC-010/011
    # verification, so the operator is told to confirm it with its signer set
    # rather than having state flipped on a bare status read.
    def reconcile
      rescue_and_log(target: @tx) do
        unless @tx.awaiting_broadcast_verdict?
          raise "Transaction is #{@tx.status} with no recorded signature — nothing to reconcile."
        end

        signature = @tx.tx_signature
        # searchTransactionHistory: true — a plain getTransaction at `confirmed`
        # returns nothing for a merely unindexed transaction, which would read
        # as "never landed" and rewind a row that is still on its way.
        status = Solana::Vault.new.client.confirm_transaction(signature).dig("value", 0)

        notice =
          case @tx.reconcile_broadcast!(status)
          when :landed
            "This transaction LANDED on chain (#{signature}). Confirm it with its signer set " \
            "to record the authorisation; it will not be re-broadcast."
          when :failed
            "This transaction landed and FAILED on chain (#{signature}), so the treasury did " \
            "not move. The row is pending again and can be rebuilt."
          when :never_landed
            "This transaction never landed and its blockhash window has lapsed, so it can " \
            "never land. The row is pending again and can be rebuilt."
          else
            "Still unresolved — the transaction may yet land, so the row stays claimed. " \
            "Do not re-send it; reconcile again shortly."
          end

        respond_to do |format|
          format.json { render json: { status: @tx.reload.status, tx_signature: @tx.tx_signature, message: notice } }
          format.html { redirect_to admin_pending_transactions_path, notice: notice }
        end
      end
    rescue StandardError => e
      respond_to do |format|
        format.json { render json: { error: e.message }, status: :unprocessable_entity }
        format.html { redirect_to admin_pending_transactions_path, alert: "Reconciliation failed: #{e.message}" }
      end
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

        # CONDITIONAL, not a bare write. `pending?` was read at the top of this
        # action; a #broadcast request that claimed the row in the interval
        # would be un-claimed by an unconditional `status: "pending"` here — the
        # last path that could hand a second caller a row whose wire is already
        # going out. The UPDATE re-checks the state it assumed.
        rebuilt = PendingTransaction.where(id: @tx.id, status: "pending")
                                    .update_all(serialized_tx: result[:serialized_tx],
                                                updated_at: Time.current) == 1
        unless rebuilt
          raise "This transaction is no longer pending (it is now #{@tx.reload.status}) — " \
                "reconcile it on chain rather than rebuilding it."
        end
        @tx.reload

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
