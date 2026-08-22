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
  #        resolution + amount — the client never dictates either).
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
