module Webhooks
  class StripeController < ApplicationController # parked: FiatRailsParked, docs/FIAT_RAILS.md
    skip_before_action :verify_authenticity_token
    skip_before_action :require_authentication
    skip_before_action :detect_geo_state
    skip_before_action :require_profile_completion

    def create
      payload = request.body.read
      sig_header = request.env["HTTP_STRIPE_SIGNATURE"]
      webhook_secret = ENV["STRIPE_WEBHOOK_SECRET"]

      begin
        event = Stripe::Webhook.construct_event(payload, sig_header, webhook_secret)
      rescue JSON::ParserError
        Rails.logger.warn "[tokens] webhook.bad_json"
        return head :bad_request
      rescue Stripe::SignatureVerificationError
        Rails.logger.warn "[tokens] webhook.bad_signature"
        return head :bad_request
      end

      Rails.logger.info "[tokens] webhook.received type=#{event.type} id=#{event.id} livemode=#{event.livemode}"

      # OPSEC-033: refuse test-mode events in production at the controller
      # boundary, before the validator's re-fetch. Protects against an
      # operator misconfig where STRIPE_SECRET_KEY accidentally holds a
      # test key (defense-in-depth on top of OPSEC-032's boot-time check).
      if Rails.env.production? && !event.livemode
        Rails.logger.warn "[tokens] webhook.rejected_test_event_in_production type=#{event.type} id=#{event.id}"
        return head :ok
      end

      case event.type
      when "checkout.session.completed"
        # Dump key fields from the event payload (not the full blob — Stripe sessions are huge).
        s = event.data.object
        TokensLogger.dump("webhook.event_payload", {
          session_id:     s.id,
          payment_status: s.payment_status,
          status:         s.status,
          amount_total:   s.amount_total,
          currency:       s.currency,
          livemode:       s.livemode,
          mode:           s.mode,
          metadata:       s.metadata.to_h,
          customer_email: s.customer_email,
          payment_intent: s.payment_intent
        })
        handle_checkout_completed(s)
      when "charge.dispute.created", "charge.dispute.funds_withdrawn"
        # OPSEC-036: a chargeback. Flag the buyer + record it so the operator
        # isn't silently defrauded (stolen-card token buy → dispute weeks later).
        handle_dispute(event.data.object)
      when "charge.refunded"
        handle_refund(event.data.object)
      else
        Rails.logger.info "[tokens] webhook.ignored type=#{event.type}"
      end

      head :ok
    end

    private

    def handle_checkout_completed(session_from_event)
      stripe_session_id = session_from_event.id
      kind = session_from_event.metadata["kind"] || "deposit"
      sid_short = stripe_session_id[0, 24]
      Rails.logger.info "[tokens] webhook.checkout_completed sid=#{sid_short}... kind=#{kind}"

      # Re-fetch from Stripe + validate payment_status / amount / livemode / kind
      # before doing anything. Signed payload only proves authenticity; this proves
      # the payment actually cleared and the data matches what we expected.
      result = StripeCheckoutValidator.new(stripe_session_id, kind: kind).call

      unless result.ok?
        Rails.logger.warn "[tokens] webhook.validator_rejected sid=#{sid_short}... reason=#{result.reason}"
        return
      end

      # Use the re-fetched session — authoritative.
      session        = result.session
      user_id        = session.metadata["user_id"]
      wallet_address = session.metadata["wallet_address"]
      Rails.logger.info "[tokens] webhook.validator_ok user=#{user_id} qty=#{session.metadata["quantity"]} amount=#{session.amount_total}"

      if kind == "tokens"
        TokenPurchaseJob.perform_later(
          user_id: user_id,
          pack_id: session.metadata["pack_id"],
          wallet_address: wallet_address,
          stripe_session_id: stripe_session_id
        )
        Rails.logger.info "[tokens] webhook.job_enqueued sid=#{sid_short}..."
      else
        # OPSEC-008: trust session.amount_total (Stripe's authoritative figure)
        # for the deposit amount. metadata.amount_cents is only a sanity check
        # cross-referenced inside StripeCheckoutValidator; if it ever diverged
        # the validator would have rejected upstream with :amount_mismatch.
        StripeDepositJob.perform_later(
          user_id: user_id,
          amount_cents: session.amount_total.to_i,
          wallet_address: wallet_address,
          stripe_session_id: stripe_session_id
        )
      end
    end

    # OPSEC-036 + B4/OPSEC-048: dispute → flag (blocks future card purchases)
    # AND freeze (blocks entry/withdraw/spend while ops reviews).
    def handle_dispute(dispute)
      purchase = stripe_purchase_for_payment_intent(dispute.payment_intent)
      if purchase
        purchase.user.update!(payment_risk_flag: true)
        purchase.user.freeze_for_payment_risk!(reason: "stripe.dispute charge=#{dispute.charge} reason=#{dispute.reason}")
        Rails.logger.error "[tokens] webhook.dispute user=#{purchase.user_id} purchase=#{purchase.id} " \
          "charge=#{dispute.charge} reason=#{dispute.reason} amount=#{dispute.amount} — user flagged AND frozen"
      else
        Rails.logger.error "[tokens] webhook.dispute UNMATCHED charge=#{dispute.charge} pi=#{dispute.payment_intent} " \
          "reason=#{dispute.reason} amount=#{dispute.amount} — manual review required"
      end
    end

    # OPSEC-036 + B4/OPSEC-048: refund → mark refunded AND freeze (operator
    # unfreezes via rails console for legit refunds).
    def handle_refund(charge)
      purchase = stripe_purchase_for_payment_intent(charge.payment_intent)
      if purchase
        purchase.mark_refunded!(reason: "stripe charge.refunded") unless purchase.status == "refunded"
        purchase.user.freeze_for_payment_risk!(reason: "stripe.refund charge=#{charge.id}")
        Rails.logger.warn "[tokens] webhook.refund purchase=#{purchase.id} user=#{purchase.user_id} charge=#{charge.id} — marked refunded AND user frozen"
      else
        Rails.logger.warn "[tokens] webhook.refund UNMATCHED charge=#{charge.id} pi=#{charge.payment_intent}"
      end
    end

    # Dispute/refund events carry a payment_intent, not a checkout session id.
    # StripePurchase is keyed by session id, so resolve pi → session → purchase.
    def stripe_purchase_for_payment_intent(payment_intent_id)
      return nil if payment_intent_id.blank?

      sessions = Stripe::Checkout::Session.list(payment_intent: payment_intent_id, limit: 1)
      session_id = sessions.data.first&.id
      return nil if session_id.blank?

      StripePurchase.for_session(session_id).first
    rescue Stripe::StripeError => e
      Rails.logger.error "[tokens] webhook.purchase_lookup_failed pi=#{payment_intent_id}: #{e.message}"
      nil
    end
  end
end
