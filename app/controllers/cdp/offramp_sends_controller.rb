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
  #        admin (fee payer) signature slot, and hands back the fully-signed
  #        bytes for the client to broadcast. One cosign per row.
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
    # endpoint validates and cosigns, and the client broadcasts the result.
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
        # A row already :sending has been cosigned once. Re-arm it ONLY when an
        # on-chain read proves that send never landed (see #rearm_stalled_send!).
        unless rearm_stalled_send!
          return render json: {
            error: "This cash-out was already sent. Give it a moment to confirm.",
            tx_signature: @ramp.sent_signature
          }, status: :unprocessable_entity
        end

        destination = OfframpDestination.resolve(@ramp.to_address)
        vault = Solana::Vault.new

        # Audit C1 (admin blind-cosign): SEMANTICALLY validate the Phantom-signed
        # wire BEFORE the house signs anything. The admin is the fee payer here,
        # so an unguarded cosign would let a crafted wire spend the admin's
        # signature on something other than this cash-out. Validate-then-cosign:
        # on reject nothing is signed and nothing is broadcastable.
        vault.assert_usdc_transfer_cosign_safe!(
          signed_tx,
          wallet_address: @ramp.wallet_address,
          destination_token_account: destination.token_account,
          amount_lamports: amount,
          context: "offramp_send:#{@ramp.partner_user_ref}"
        )
        cosigned = vault.cosign_usdc_transfer(signed_tx)

        # Persist the signature BEFORE the signed bytes leave the server. Once
        # the client holds a fully-signed wire the broadcast is out of our hands,
        # and a row that never learned the signature could not be reconciled
        # against the chain. This is also the ONE-COSIGN-PER-ROW cap: the row
        # leaves :cdp_created here, so the endpoint cannot be looped into a
        # house-funded fee faucet. #sent still verifies on-chain and advances
        # the row to :sent.
        @ramp.mark_sending!(cosigned[:signature])

        render json: {
          signed_tx: cosigned[:signed_tx],
          tx_signature: cosigned[:signature],
          wallet_address: @ramp.wallet_address
        }
      end
    rescue Solana::Vault::UnsafeCosignError
      # The detailed reason is logged server-side by the guard and is NEVER
      # returned to the client.
      render json: { error: "That transaction didn't match your cash-out, so it wasn't signed. Please start the cash-out again." },
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

    # One cosign per cash-out row. #cosign moves the row to :sending the moment
    # the house signs, so a client cannot loop the endpoint and mint an
    # unbounded supply of broadcastable, house-funded wires — every broadcast
    # costs the house its fee whether the transfer succeeds or fails.
    #
    # The legitimate retry (the browser never managed to broadcast) is re-armed
    # here, and ONLY after an on-chain read proves the recorded signature never
    # landed. That is exactly the rewind CdpRampTransaction#reset_failed_send!
    # exists for. Returns false when the recorded send DID land — the caller
    # should report that signature to #sent rather than sign a second transfer.
    def rearm_stalled_send!
      return true unless @ramp.sending?

      signature = @ramp.sent_signature.to_s
      return true if signature.blank?

      tx_info = Solana::Config.client.get_transaction(signature)
      return false if tx_info && tx_info.dig("meta", "err").nil?

      @ramp.reset_failed_send!
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
