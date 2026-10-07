module Webhooks
  # PayPal webhook handler — the PayPal-rails sibling of Webhooks::StripeController.
  #
  # Fulfillment source of truth: PAYMENT.CAPTURE.COMPLETED (validate-then-mint).
  # CHECKOUT.ORDER.APPROVED is the client-died fallback — the buyer approved in
  # PayPal/Venmo but onApprove never reached /tokens/paypal_capture, so we
  # capture server-side. Exactly-once minting is arbitrated by
  # PaypalPurchase#begin_fulfillment! via Paypal::Fulfillment.
  class PaypalController < ApplicationController # parked: FiatRailsParked, docs/FIAT_RAILS.md
    skip_before_action :verify_authenticity_token
    skip_before_action :require_authentication
    skip_before_action :detect_geo_state
    skip_before_action :require_profile_completion

    VERIFICATION_HEADERS = %w[
      PAYPAL-AUTH-ALGO PAYPAL-CERT-URL PAYPAL-TRANSMISSION-ID
      PAYPAL-TRANSMISSION-SIG PAYPAL-TRANSMISSION-TIME
    ].freeze

    def create
      raw_body = request.body.read

      begin
        event = JSON.parse(raw_body)
      rescue JSON::ParserError
        Rails.logger.warn "[tokens] paypal.webhook.bad_json"
        return head :bad_request
      end

      # Verification posts the RAW body back to PayPal verbatim — see
      # Paypal::Client#verify_webhook_signature.
      unless Paypal::Client.new.verify_webhook_signature(headers: verification_headers, raw_body: raw_body)
        Rails.logger.warn "[tokens] paypal.webhook.bad_signature id=#{event['id']}"
        return head :bad_request
      end

      event_type = event["event_type"].to_s
      Rails.logger.info "[tokens] paypal.webhook.received type=#{event_type} id=#{event['id']}"

      # OPSEC-033 parity: refuse sandbox events in production at the controller
      # boundary. PayPal events carry no livemode flag, so two tells are used:
      # a sandbox-configured client (PAYPAL_ENV) or an event self-referencing
      # the sandbox API host in its HATEOAS links. Return 200 to ack.
      if Rails.env.production? && (Paypal::Client.sandbox? || sandbox_event?(event))
        Rails.logger.warn "[tokens] paypal.webhook.rejected_sandbox_event_in_production type=#{event_type} id=#{event['id']}"
        return head :ok
      end

      resource = event["resource"] || {}

      case event_type
      when "PAYMENT.CAPTURE.COMPLETED"
        handle_capture_completed(resource)
      when "CHECKOUT.ORDER.APPROVED"
        handle_order_approved(resource)
      when "PAYMENT.CAPTURE.DENIED"
        handle_capture_denied(resource)
      when "PAYMENT.CAPTURE.REFUNDED"
        handle_refund(resource)
      when "CUSTOMER.DISPUTE.CREATED"
        handle_dispute(resource)
      else
        Rails.logger.info "[tokens] paypal.webhook.ignored type=#{event_type}"
      end

      head :ok
    end

    private

    def verification_headers
      VERIFICATION_HEADERS.index_with { |name| request.headers[name] }
    end

    def sandbox_event?(event)
      links = [event["links"], event.dig("resource", "links")].flatten.compact
      # Match the bare host suffix: PayPal HATEOAS links use BOTH
      # api.sandbox.paypal.com and api-m.sandbox.paypal.com (the client's own
      # SANDBOX_BASE is the api-m form); matching the api-only literal missed
      # the api-m hosts. The live host (api-m.paypal.com) can't match this.
      links.any? { |link| link.is_a?(Hash) && link["href"].to_s.include?(".sandbox.paypal.com") }
    end

    # resource = the capture object. Signature verification proves authenticity;
    # capture_matches? proves the payment cleared for the exact pack amount in
    # USD before anything mints (StripeCheckoutValidator parity).
    def handle_capture_completed(capture)
      purchase = purchase_for_capture(capture)
      unless purchase
        Rails.logger.error "[tokens] paypal.webhook.capture_completed UNMATCHED capture=#{capture['id']} " \
                           "custom_id=#{capture['custom_id']} — manual review required"
        return
      end

      TokensLogger.dump("paypal.webhook.capture_payload", {
        capture_id: capture["id"],
        status: capture["status"],
        amount: capture["amount"],
        custom_id: capture["custom_id"],
        invoice_id: capture["invoice_id"]
      })

      unless purchase.capture_matches?(capture)
        Rails.logger.warn "[tokens] paypal.webhook.capture_rejected purchase=#{purchase.id} " \
                          "status=#{capture['status']} amount=#{capture.dig('amount', 'value')} " \
                          "expected=#{purchase.expected_amount_value}"
        return
      end

      if Paypal::Fulfillment.enqueue_mint!(purchase, capture_id: capture["id"])
        Rails.logger.info "[tokens] paypal.webhook.job_enqueued purchase=#{purchase.id}"
      else
        Rails.logger.info "[tokens] paypal.webhook.already_fulfilled purchase=#{purchase.id} status=#{purchase.status}"
      end
    end

    # resource = the order object. Client-died fallback: capture server-side
    # when our purchase is still pending. The capture call carries an
    # idempotent PayPal-Request-Id, so racing the client's paypal_capture is
    # safe — PayPal returns the same capture to both.
    def handle_order_approved(order)
      order_id = order["id"].to_s
      purchase = PaypalPurchase.for_order(order_id).first
      unless purchase
        Rails.logger.warn "[tokens] paypal.webhook.order_approved UNMATCHED order=#{order_id}"
        return
      end
      return unless purchase.status == "pending"

      # B4 / OPSEC-036/048: the client capture leg enforces these gates in
      # TokensController (require_unfrozen_account + the risk-flag check);
      # this server-initiated fallback must too, or a buyer approving a
      # leftover pending order post-freeze would have US capture the money
      # and mint for exactly the account the freeze exists to stop.
      if purchase.user.frozen? || purchase.user.payment_risk_flag
        Rails.logger.warn "[tokens] paypal.webhook.order_approved_blocked purchase=#{purchase.id} " \
                          "user=#{purchase.user_id} frozen=#{purchase.user.frozen?} " \
                          "risk_flag=#{purchase.user.payment_risk_flag} — capture skipped"
        return
      end

      Current.outbound_source = purchase
      Current.user            = purchase.user

      response = Paypal::Client.new.capture_order(order_id)
      capture  = response.dig("purchase_units", 0, "payments", "captures", 0)
      unless response["status"] == "COMPLETED" && purchase.capture_matches?(capture)
        Rails.logger.warn "[tokens] paypal.webhook.order_approved_capture_invalid purchase=#{purchase.id} " \
                          "order_status=#{response['status']} capture_status=#{capture&.dig('status')}"
        return
      end

      Paypal::Fulfillment.enqueue_mint!(purchase, capture_id: capture["id"])
      Rails.logger.info "[tokens] paypal.webhook.order_approved_captured purchase=#{purchase.id} capture=#{capture['id']}"
    rescue Paypal::Client::Error => e
      # e.g. ORDER_ALREADY_CAPTURED — the client-side capture won the race;
      # PAYMENT.CAPTURE.COMPLETED carries the authoritative result.
      Rails.logger.warn "[tokens] paypal.webhook.order_approved_capture_failed order=#{order_id}: #{e.message}"
    end

    def handle_capture_denied(capture)
      purchase = purchase_for_capture(capture)
      unless purchase
        Rails.logger.warn "[tokens] paypal.webhook.capture_denied UNMATCHED capture=#{capture['id']}"
        return
      end
      purchase.mark_failed_unless_minted!
      Rails.logger.error "[tokens] paypal.webhook.capture_denied purchase=#{purchase.id} user=#{purchase.user_id} capture=#{capture['id']}"
    end

    # OPSEC-036 + B4/OPSEC-048 parity with Stripe handle_refund: mark refunded
    # AND freeze (operator unfreezes via rails console for legit refunds).
    # resource = the refund object.
    def handle_refund(refund)
      purchase = purchase_for_refund(refund)
      if purchase
        purchase.mark_refunded!(reason: "paypal payment.capture.refunded") unless purchase.status == "refunded"
        purchase.user.freeze_for_payment_risk!(reason: "paypal.refund capture=#{purchase.capture_id} refund=#{refund['id']}")
        Rails.logger.warn "[tokens] paypal.webhook.refund purchase=#{purchase.id} user=#{purchase.user_id} " \
                          "refund=#{refund['id']} — marked refunded AND user frozen"
      else
        Rails.logger.warn "[tokens] paypal.webhook.refund UNMATCHED refund=#{refund['id']}"
      end
    end

    # OPSEC-036 + B4/OPSEC-048 parity with Stripe handle_dispute: flag the
    # buyer (blocks future fiat purchases) AND freeze (blocks entry/withdraw/
    # spend while ops reviews). Tokens already minted stay on-chain; operator
    # decides recovery. resource = the dispute object.
    def handle_dispute(dispute)
      capture_ids = Array(dispute["disputed_transactions"]).filter_map { |txn| txn["seller_transaction_id"] }
      purchase = capture_ids.any? ? PaypalPurchase.where(capture_id: capture_ids).first : nil
      if purchase
        purchase.user.update!(payment_risk_flag: true)
        purchase.user.freeze_for_payment_risk!(reason: "paypal.dispute id=#{dispute['dispute_id']} reason=#{dispute['reason']}")
        Rails.logger.error "[tokens] paypal.webhook.dispute user=#{purchase.user_id} purchase=#{purchase.id} " \
                           "dispute=#{dispute['dispute_id']} reason=#{dispute['reason']} — user flagged AND frozen"
      else
        Rails.logger.error "[tokens] paypal.webhook.dispute UNMATCHED dispute=#{dispute['dispute_id']} " \
                           "captures=#{capture_ids.inspect} — manual review required"
      end
    end

    # A capture resource carries our custom_id ("paypal_purchase:<id>"), its
    # parent order id under supplementary_data, and the purchase slug as
    # invoice_id — try each in turn.
    def purchase_for_capture(capture)
      if (purchase_id = capture["custom_id"].to_s[/\Apaypal_purchase:(\d+)\z/, 1])
        purchase = PaypalPurchase.find_by(id: purchase_id)
        return purchase if purchase
      end
      order_id = capture.dig("supplementary_data", "related_ids", "order_id")
      if order_id.present?
        purchase = PaypalPurchase.for_order(order_id).first
        return purchase if purchase
      end
      PaypalPurchase.find_by(slug: capture["invoice_id"]) if capture["invoice_id"].present?
    end

    # Refund resources also carry custom_id/invoice_id; the "up" HATEOAS link
    # points at the refunded capture (.../v2/payments/captures/<id>).
    def purchase_for_refund(refund)
      if (purchase_id = refund["custom_id"].to_s[/\Apaypal_purchase:(\d+)\z/, 1])
        purchase = PaypalPurchase.find_by(id: purchase_id)
        return purchase if purchase
      end
      up = Array(refund["links"]).find { |link| link["rel"] == "up" }
      capture_id = up && up["href"].to_s[%r{/captures/([^/]+)\z}, 1]
      PaypalPurchase.find_by(capture_id: capture_id) if capture_id.present?
    end
  end
end
