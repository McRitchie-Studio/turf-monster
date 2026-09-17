module Cdp
  # The offramp SEND half of §10 (docs/CDP_RAMP_INTEGRATION.md) — after the
  # poll job discovers to_address, the user has ~30 minutes to move the USDC.
  # Three same-origin authedFetch POSTs, all keyed on partner_user_ref and
  # scoped to the viewer's own offramp rows:
  #
  #   POST /cdp/offramp/confirm_send  — managed (web2): the FRESH explicit
  #        user confirmation; stamps confirmed_at + enqueues OfframpSendJob.
  #        The server NEVER moves managed funds without this click.
  #   POST /cdp/offramp/prepare_send  — Phantom (web3): server builds the
  #        unsigned USDC transfer (single source of truth for destination
  #        resolution + amount — the client never dictates either). The HOUSE
  #        is the fee payer on that wire, so a Phantom player holding USDC and
  #        zero SOL can still withdraw (phantom-cashout-needs-sol).
  #   POST /cdp/offramp/cosign_send   — Phantom (web3): validates the
  #        Phantom-signed wire against what THIS server prepared, fills the
  #        admin (fee payer) signature slot, simulates the result, and hands
  #        back the fully-signed bytes for the client to broadcast only when the
  #        simulation passes. One cosign per row.
  #   POST /cdp/offramp/sent          — Phantom (web3): records the
  #        client-reported signature AFTER verifying it on-chain (never trust
  #        an unverified client signature — the Lazarus recover_pending_entry
  #        bug class), so the poll job/CDP settlement reconciles against it.
  class OfframpSendsController < BaseController
    # B4 / OPSEC-048: these endpoints move money — frozen accounts can't.
    before_action :require_unfrozen_account
    before_action :set_ramp

    # Managed mode. Idempotent-friendly: a row already in flight reports its
    # status instead of erroring, so a double-click converges.
    def confirm
      return render_mode_error("managed") unless @ramp.wallet_web2?
      if @ramp.sending? || @ramp.sent?
        return render json: { ok: true, status: @ramp.status }
      end
      return render_state_error unless @ramp.cdp_created?
      return render_deadline_error unless within_send_window?
      return render_minimum_error if below_minimum_withdrawal?

      rescue_and_log(target: @ramp, parent: current_user) do
        @ramp.update!(confirmed_at: Time.current)
        OfframpSendJob.perform_later(ramp_id: @ramp.id)
        render json: { ok: true, status: @ramp.reload.status }
      end
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # Phantom mode: resolve the destination on-chain (gates every send) and
    # hand back the unsigned single-signer tx for Phantom to sign + broadcast.
    def prepare
      return render_mode_error("Phantom") unless @ramp.wallet_web3?
      return render_state_error unless @ramp.cdp_created?
      return render_deadline_error unless within_send_window?

      amount = amount_base_units
      if amount <= 0
        return render json: { error: "Cash-out amount isn't known yet — please retry in a moment." },
                      status: :unprocessable_entity
      end
      # Refuse the dust withdrawal HERE, with copy naming the floor, before the
      # builder's own unbypassable assertion turns it into a generic error.
      return render_minimum_error if below_minimum_withdrawal?

      rescue_and_log(target: @ramp, parent: current_user) do
        destination = OfframpDestination.resolve(@ramp.to_address)
        built = Solana::Vault.new.build_user_usdc_transfer_unsigned(
          wallet_address: @ramp.wallet_address,
          destination_token_account: destination.token_account,
          amount_lamports: amount
        )
        # The prepare click is the explicit confirmation in Phantom mode (the
        # wallet popup is a second one) — stamp it for the same audit trail.
        @ramp.update!(confirmed_at: Time.current)
        render json: {
          serialized_tx: built[:serialized_tx],
          wallet_address: @ramp.wallet_address,
          destination_token_account: destination.token_account,
          amount_base_units: amount,
          cashout_deadline_at: @ramp.cashout_deadline_at&.iso8601
        }
      end
    rescue Solana::Vault::BelowMinimumWithdrawalError
      render_minimum_error
    rescue OfframpDestination::ResolutionError
      render json: { error: "Couldn't verify the Coinbase destination address — cash-out is paused for safety." },
             status: :unprocessable_entity
    rescue Solana::Client::RpcError
      render json: { error: "Solana is busy right now — please try again in a moment." },
             status: :bad_gateway
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # Phantom mode: fill the house's fee-payer signature slot.
    #
    # Since phantom-cashout-needs-sol the cash-out wire names the ADMIN as fee
    # payer (Solana::Vault#build_user_usdc_transfer_unsigned), so Phantom's
    # signature alone does not make it broadcastable. Phantom signs first, this
    # endpoint validates, cosigns and simulates, and the client broadcasts the
    # result.
    #
    # The destination and amount are re-resolved HERE from the ramp row and are
    # never read off the request, so the guard measures the returned wire
    # against the server's own answer — the same source of truth #prepare used.
    def cosign
      return render_mode_error("Phantom") unless @ramp.wallet_web3?
      return render_state_error unless @ramp.cdp_created? || @ramp.sending?
      return render_deadline_error unless within_send_window?
      return render_minimum_error if below_minimum_withdrawal?

      signed_tx = params[:signed_tx].to_s
      if signed_tx.blank?
        return render json: { error: "signed_tx is required" }, status: :unprocessable_entity
      end

      amount = amount_base_units
      if amount <= 0
        return render json: { error: "Cash-out amount isn't known yet — please retry in a moment." },
                      status: :unprocessable_entity
      end

      rescue_and_log(target: @ramp, parent: current_user) do
        # NETWORK I/O FIRST, OUTSIDE THE LOCK. Both reads below are RPC, and a
        # row lock held across a network call ties up a database connection for
        # the length of somebody else's outage.
        destination = OfframpDestination.resolve(@ramp.to_address)
        probed_signature = @ramp.sending? ? @ramp.sent_signature.to_s : ""
        probed_status = probed_signature.present? ? recorded_send_status(probed_signature) : nil

        vault = Solana::Vault.new
        outcome = nil
        signed = nil
        cosigned = nil

        # EVERYTHING THAT DECIDES OR MUTATES STATE RUNS UNDER THE ROW LOCK, in
        # two holds, because the pre-flight simulation between them is RPC. The
        # first decides whether this row may send at all, then guards and
        # cosigns; the second takes the claim. Without a lock two concurrent
        # requests both read :cdp_created and both walk away with a
        # broadcastable, house-funded wire for the SAME cash-out. Two requests
        # can still both reach a cosign here, but only one can claim, and only
        # the claimant's bytes are rendered. with_lock reloads, so every check
        # below sees fresh state. Only CPU work and UPDATEs happen inside either
        # hold — no RPC.
        @ramp.with_lock do
          if @ramp.sending? && @ramp.sent_signature.to_s != probed_signature
            # The row moved while we were on the network, so the verdict we
            # hold describes a DIFFERENT send. Refuse rather than rewind on a
            # stale probe.
            outcome = :in_flight
          else
            case rearm_verdict(probed_status)
            when :already_sent then outcome = :already_sent
            when :in_flight    then outcome = :in_flight
            else
              # Audit C1 (admin blind-cosign): SEMANTICALLY validate the
              # Phantom-signed wire BEFORE the house signs anything. The admin
              # is the fee payer here, so an unguarded cosign would let a
              # crafted wire spend the admin's signature on something other
              # than this cash-out. Validate-then-cosign: on reject this raises
              # and the transaction rolls back, so nothing is signed and
              # nothing is broadcastable.
              vault.assert_usdc_transfer_cosign_safe!(
                signed_tx,
                wallet_address: @ramp.wallet_address,
                destination_token_account: destination.token_account,
                amount_lamports: amount,
                context: "offramp_send:#{@ramp.partner_user_ref}"
              )
              signed = vault.cosign_usdc_transfer(signed_tx)
            end
          end
        end

        if signed
          # THE PRE-FLIGHT: simulate the house-signed bytes BEFORE the claim and
          # BEFORE they leave. The browser broadcasts this wire with
          # skipPreflight:true, so no node checks it after us, and a wire that
          # fails on chain still charges its fee payer — the house. On a failed
          # or unrunnable simulation this raises Vault::PreflightRejected: the
          # bytes are dropped, no claim was taken, and the row is exactly as the
          # first hold left it. Running it BEFORE the claim means a crash here
          # cannot leave a row claiming a signature that was never returned.
          vault.preflight_cosigned_wire!(signed[:signed_tx])

          @ramp.with_lock do
            # THE CAP IS THIS RETURN VALUE, AND IT HAS TO BE READ.
            # #mark_sending! answers false when the row is no longer claimable
            # (a concurrent request claimed it while we simulated), and a wire
            # rendered anyway is a wire that can be broadcast — which would make
            # the one-cosign-per-row cap decorative. Rendering is gated on the
            # claim SUCCEEDING.
            #
            # It also persists the signature BEFORE the signed bytes leave the
            # server: once the client holds a fully-signed wire the broadcast is
            # out of our hands, and a row that never learned the signature could
            # not be reconciled against the chain.
            if @ramp.mark_sending!(signed[:signature])
              cosigned = signed
              outcome = :ok
            else
              outcome = :claim_lost
            end
          end
        end

        case outcome
        when :ok
          render json: {
            signed_tx: cosigned[:signed_tx],
            tx_signature: cosigned[:signature],
            wallet_address: @ramp.wallet_address
          }
        when :already_sent
          render json: {
            error: "This cash-out was already sent. Give it a moment to confirm.",
            tx_signature: @ramp.sent_signature
          }, status: :unprocessable_entity
        when :in_flight
          render json: {
            error: "Your cash-out is still being confirmed on Solana. Give it a few minutes before trying again.",
            tx_signature: @ramp.sent_signature
          }, status: :unprocessable_entity
        else # :claim_lost
          render json: {
            error: "This cash-out is already being sent. Please refresh before trying again."
          }, status: :unprocessable_entity
        end
      end
    rescue Solana::Vault::UnsafeCosignError
      # The detailed reason is logged server-side by the guard and is NEVER
      # returned to the client.
      render json: { error: "That transaction didn't match your cash-out, so it wasn't signed. Please start the cash-out again." },
             status: :unprocessable_entity
    rescue Solana::Vault::PreflightRejected
      # The simulation's program error and logs are in the ErrorLog
      # rescue_and_log wrote; the player gets only what they can act on.
      render json: { error: "Solana couldn't confirm this cash-out would go through, so it wasn't signed. " \
                            "Check that your wallet still holds the USDC, then start the cash-out again." },
             status: :unprocessable_entity
    rescue Solana::Vault::BelowMinimumWithdrawalError
      render_minimum_error
    rescue OfframpDestination::ResolutionError
      render json: { error: "Couldn't verify the Coinbase destination address — cash-out is paused for safety." },
             status: :unprocessable_entity
    rescue Solana::Client::RpcError
      render json: { error: "Solana is busy right now — please try again in a moment." },
             status: :bad_gateway
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    # Phantom mode: record the client-reported signature so the poll job can
    # reconcile. Verified on-chain first — found, no err, and signed by the
    # ramp's wallet.
    def sent
      return render_mode_error("Phantom") unless @ramp.wallet_web3?

      signature = params[:tx_signature].to_s.strip
      if signature.blank?
        return render json: { error: "tx_signature is required" }, status: :unprocessable_entity
      end
      if @ramp.sent_signature.present? && @ramp.sent_signature != signature
        return render json: { error: "A different send is already recorded for this cash-out." },
                      status: :unprocessable_entity
      end

      rescue_and_log(target: @ramp, parent: current_user) do
        verify_reported_signature!(signature)
        unless @ramp.mark_sent!(signature)
          return render json: { error: "This cash-out can't accept a send in its current state (#{@ramp.status})." },
                        status: :unprocessable_entity
        end
        # Nudge reconciliation — idempotent, self-terminating loop (a second
        # schedule converges with any loop already running).
        OfframpPollJob.schedule_initial(@ramp)
        render json: { ok: true, status: @ramp.status, sent_signature: @ramp.sent_signature }
      end
    rescue SendVerificationError => e
      render json: { error: e.message }, status: :unprocessable_entity
    rescue StandardError => e
      render json: { error: e.message }, status: :unprocessable_entity
    end

    private

    class SendVerificationError < StandardError; end

    # §10: refuse sends inside the last 3 minutes of the cashout window
    # (mirrors Cdp::OfframpSendJob::DEADLINE_SAFETY — the job re-checks).
    SEND_DEADLINE_SAFETY = 3.minutes

    def set_ramp
      @ramp = current_user.cdp_ramp_transactions.offramp
                          .find_by(partner_user_ref: params[:partner_user_ref])
      render json: { error: "not found" }, status: :not_found unless @ramp
    end

    def within_send_window?
      @ramp.cashout_deadline_at.present? &&
        Time.current <= @ramp.cashout_deadline_at - SEND_DEADLINE_SAFETY
    end

    def amount_base_units
      sell = @ramp.sell_amount
      return 0 if sell.nil?
      (sell * Cdp::OfframpSendJob::USDC_BASE_UNITS_PER_USDC).to_i
    end

    # The $0.99 withdrawal floor (Solana::Vault::MIN_WITHDRAWAL_BASE_UNITS). The
    # builders assert it too, so it cannot be skipped; this copy exists so a
    # person with $0.40 reads a floor rather than a fault.
    def below_minimum_withdrawal?
      amount = amount_base_units
      amount.positive? && amount < Solana::Vault::MIN_WITHDRAWAL_BASE_UNITS
    end

    def render_minimum_error
      render json: {
        error: "Minimum withdrawal is $#{Solana::Vault::MIN_WITHDRAWAL_USD}. " \
               "This cash-out is below that, so it can't be sent.",
        minimum_usd: Solana::Vault::MIN_WITHDRAWAL_USD
      }, status: :unprocessable_entity
    end

    # The history-searched status of a recorded send. `confirm_transaction` is
    # `getSignatureStatuses` with **searchTransactionHistory: true** — the whole
    # reason this is not `get_transaction`, which at `confirmed` commitment
    # answers nil for a transaction that is merely UNINDEXED and would make an
    # in-flight send read as a dead one.
    def recorded_send_status(signature)
      Solana::Config.client.confirm_transaction(signature)&.dig("value", 0)
    end

    # ONE COSIGN PER CASH-OUT ROW, and the rewind that re-arms it.
    #
    # #cosign moves the row to :sending as soon as it returns a house-signed wire
    # that passed its simulation, so a row holds at most ONE outstanding wire —
    # every broadcast costs the house its fee whether the transfer succeeds or
    # fails. That is not a cap on attempts. The simulation sees only failures
    # present at cosign time; a wire built to fail AFTER it (a Lighthouse clock
    # assertion, or the USDC moved out first) lands as :failed, the rewind below
    # re-arms the row, and re-arms are not counted — only the send window and
    # the cdp_offramp_send/user throttle bound that loop.
    #
    # The legitimate retry — the browser never managed to broadcast — is
    # re-armed here, and ONLY on a verdict that is DEFINITIVE. The verdict
    # itself is CdpRampTransaction#send_verdict, the same one
    # Cdp::OfframpSendJob#verify_pending_send rewinds on, because a wrong
    # rewind here has the identical consequence its #blockhash_lapsed? comment
    # names: a second full-amount transfer is built and the player's USDC is
    # sent TWICE.
    #
    # :ambiguous is the common case and it REFUSES. An absent status means
    # in-flight or not-yet-indexed just as often as it means never-broadcast,
    # and only the age of the broadcast tells them apart.
    def rearm_verdict(status)
      return :proceed unless @ramp.sending?
      return :proceed if @ramp.sent_signature.blank?

      case @ramp.send_verdict(status)
      when :landed
        :already_sent
      when :failed, :never_landed
        # Verified-dead: the funds did not move and this signature can never
        # land. reset_failed_send! clears it and its broadcast_at anchor so a
        # fresh, fully re-guarded attempt can be built.
        Rails.logger.warn("[cdp][cosign] #{@ramp.partner_user_ref} sig=#{@ramp.sent_signature} " \
                          "verified dead — re-arming for a fresh cosign")
        @ramp.reset_failed_send!
        :proceed
      else
        :in_flight
      end
    end

    def render_mode_error(expected)
      render json: { error: "This cash-out isn't a #{expected}-wallet session." },
             status: :unprocessable_entity
    end

    def render_state_error
      render json: { error: "This cash-out isn't ready to send (status: #{@ramp.status})." },
             status: :unprocessable_entity
    end

    def render_deadline_error
      render json: { error: "The 30-minute send window for this cash-out has closed." },
             status: :unprocessable_entity
    end

    # Mirrors Solana::TxVerifier's posture (OPSEC-010) for a plain SPL
    # transfer: the tx must exist, have landed without error, and carry the
    # ramp's wallet in a SIGNER slot — an arbitrary successful signature
    # someone else produced can't be pinned to this cash-out.
    def verify_reported_signature!(signature)
      tx_info = Solana::Config.client.get_transaction(signature)
      raise SendVerificationError, "Transaction not found on-chain yet — wait for confirmation and retry." unless tx_info

      err = tx_info.dig("meta", "err")
      raise SendVerificationError, "Transaction failed on-chain (#{err.inspect})." if err

      message = tx_info.dig("transaction", "message")
      # Test stubs (config/initializers/test_solana_stubs.rb) return a
      # permissive { transaction: {} } shape for MockTxSignature… inputs —
      # same carve-out Solana::TxVerifier makes.
      return true if message.nil? && Rails.env.test?
      raise SendVerificationError, "Transaction missing message data." if message.nil?

      account_keys = message["accountKeys"] || []
      num_signers = message.dig("header", "numRequiredSignatures").to_i
      idx = account_keys.index(@ramp.wallet_address)
      unless idx && idx < num_signers
        raise SendVerificationError, "Transaction was not signed by this cash-out's wallet."
      end
      true
    end
  end
end
