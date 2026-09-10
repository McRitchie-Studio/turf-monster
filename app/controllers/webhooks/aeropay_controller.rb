module Webhooks
  # Aeropay webhook handler — the Aeropay-rails sibling of
  # Webhooks::CoinflowController.
  #
  # Fulfillment source of truth: the `transaction_completed` topic (the deposit
  # was approved) → validate-then-mint. `transaction_declined` /
  # `transaction_refunded` / `transaction_voided` are logged and 200-acked (no
  # mutation — parity with Coinflow, which log-onlys its non-mint events; wiring
  # decline→failed / refund→refunded is a follow-up).
  #
  # [FLAG] Aeropay authenticates with an HMAC signature over the raw body
  # (AEROPAY_WEBHOOK_SIGNING_KEY), assumed hex HMAC-SHA256 in X-Aeropay-Signature
  # — NOT a shared secret like Coinflow. CONFIRM the exact scheme + header name
  # against dev.aero.inc/docs/webhooks-1 when creds land. Exactly-once minting is
  # arbitrated by AeropayPurchase#begin_fulfillment! via Aeropay::Fulfillment.
  #
  # Payload shape [FLAG]: { topic, data, payloadVersion, date }. The transaction
  # id + amount + currency + our externalId ride under `data`.
  class AeropayController < ApplicationController
    skip_before_action :verify_authenticity_token
    skip_before_action :require_authentication
    skip_before_action :detect_geo_state
    skip_before_action :require_profile_completion

    # [FLAG] Signature header name — assumed. Confirm against dev.aero.inc/docs.
    SIGNATURE_HEADER = "X-Aeropay-Signature".freeze

    def create
      raw_body  = request.body.read
      signature = request.headers[SIGNATURE_HEADER]

      # HMAC signature check FIRST — cheap, constant-time, fails closed. A wrong
      # (or missing) signature is the whole defense between an attacker and free
      # token minting.
      unless Aeropay::Client.new.verify_webhook(raw_body, signature)
        Rails.logger.warn "[tokens] aeropay.webhook.bad_signature"
        return head :unauthorized
      end

      begin
        event = JSON.parse(raw_body)
      rescue JSON::ParserError
        Rails.logger.warn "[tokens] aeropay.webhook.bad_json"
        return head :bad_request
      end

      topic          = event["topic"].to_s
      data           = event["data"].is_a?(Hash) ? event["data"] : {}
      transaction_id = self.class.transaction_id(event, data)
      Rails.logger.info "[tokens] aeropay.webhook.received topic=#{topic} txn=#{transaction_id}"

      # OPSEC-033 parity: refuse sandbox events in production at the controller
      # boundary. A sandbox-configured client (AEROPAY_API_BASE) is the tell.
      # Return 200 to ack (never retry-loop the sender).
      if Rails.env.production? && Aeropay::Client.sandbox?
        Rails.logger.warn "[tokens] aeropay.webhook.rejected_sandbox_event_in_production topic=#{topic} txn=#{transaction_id}"
        return head :ok
      end

      # OPSEC-033 parity: an event for a different merchant is not ours.
      merchant_id    = ENV["AEROPAY_MERCHANT_ID"].to_s
      event_merchant = (data["merchantId"] || event["merchantId"]).to_s
      if merchant_id.present? && event_merchant.present? && event_merchant != merchant_id
        Rails.logger.warn "[tokens] aeropay.webhook.merchant_mismatch event_merchant=#{event_merchant} txn=#{transaction_id}"
        return head :ok
      end

      case topic
      when "transaction_completed"
        handle_completed(event, data, transaction_id)
      when "transaction_declined", "transaction_refunded", "transaction_voided"
        # Non-mint terminals — log only for now (parity with Coinflow's non-mint
        # events). Follow-up: wire declined/voided → mark_failed and refunded →
        # mark_refunded once the sandbox confirms these payloads.
        Rails.logger.info "[tokens] aeropay.webhook.non_mint topic=#{topic} txn=#{transaction_id} (no mint)"
      else
        Rails.logger.info "[tokens] aeropay.webhook.ignored topic=#{topic} txn=#{transaction_id}"
      end

      head :ok
    end

    private

    # `transaction_completed` — the deposit was approved. Resolve the purchase,
    # dedup a redelivered event, validate the amount against the pack (never
    # trust the sender), then hand off to the exactly-once mint gate.
    def handle_completed(event, data, transaction_id)
      purchase = purchase_for_event(event, data, transaction_id)
      unless purchase
        Rails.logger.error "[tokens] aeropay.webhook.completed UNMATCHED txn=#{transaction_id} " \
                           "external=#{data['externalId']} — manual review required"
        return
      end

      TokensLogger.dump("aeropay.webhook.completed_payload", {
        transaction_id: transaction_id,
        amount:         data["amount"],
        currency:       data["currency"],
        external_id:    data["externalId"],
        merchant_id:    data["merchantId"],
        topic:          event["topic"]
      })

      # Dedup (webhooks may arrive more than once): this exact settlement already
      # drove this purchase to minted — ack and stop.
      if purchase.aeropay_transaction_id == transaction_id && purchase.status == "minted"
        Rails.logger.info "[tokens] aeropay.webhook.duplicate txn=#{transaction_id} purchase=#{purchase.id} already minted"
        return
      end

      unless purchase.capture_matches?(data)
        Rails.logger.warn "[tokens] aeropay.webhook.completed_rejected purchase=#{purchase.id} " \
                          "amount=#{data['amount']} currency=#{data['currency']} " \
                          "expected=#{purchase.expected_amount_cents}"
        return
      end

      if Aeropay::Fulfillment.enqueue_mint!(purchase, transaction_id: transaction_id)
        Rails.logger.info "[tokens] aeropay.webhook.job_enqueued purchase=#{purchase.id}"
      else
        Rails.logger.info "[tokens] aeropay.webhook.already_fulfilled purchase=#{purchase.id} status=#{purchase.status}"
      end
    end

    # Tiered resolution (Webhooks::CoinflowController#purchase_for_event
    # parity). Unlike Coinflow (whose payment id only arrives at settlement),
    # the Aeropay transaction id is stamped on the row at order time, so tier 1
    # is an EXACT transaction-id match.
    #   Tier 1 — the transaction id (stamped at order time by aeropay_order).
    #   Tier 2 — our externalId, echoed back as a reference.
    #   Tier 3 — a customerId of the shape "tm_user_<id>" → the user's oldest
    #            pending row (oldest-first so N concurrent settlements consume N
    #            pending rows, one token each — never double-minting one row).
    def purchase_for_event(event, data, transaction_id)
      if transaction_id.present? && (purchase = AeropayPurchase.for_transaction(transaction_id).first)
        return purchase
      end

      reference = (data["externalId"] || data["reference"] || event["externalId"]).presence
      if reference && (purchase = AeropayPurchase.for_reference(reference).first)
        return purchase
      end

      customer_id = (data["customerId"] || data["userId"] || event["customerId"]).to_s
      if (user_id = customer_id[/\Atm_user_(\d+)\z/, 1])
        return AeropayPurchase.where(user_id: user_id, status: "pending").order(:created_at).first
      end

      nil
    end

    # [FLAG] Transaction id lives under data.id / data.transactionId, falling
    # back to a top-level id. Confirm against dev.aero.inc/docs/webhooks-1.
    def self.transaction_id(event, data)
      (data["id"] || data["transactionId"] || event["id"]).to_s
    end
  end
end
