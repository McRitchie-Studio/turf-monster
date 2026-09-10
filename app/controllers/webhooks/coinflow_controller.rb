module Webhooks
  # Coinflow webhook handler — the Coinflow-rails sibling of
  # Webhooks::PaypalController.
  #
  # Fulfillment source of truth: the `Settled` event (funds reached settlement)
  # → validate-then-mint. `Card Payment Authorized` is pre-capture (log only).
  # Coinflow authenticates with a SHARED SECRET (Authorization header ==
  # COINFLOW_WEBHOOK_VALIDATION_KEY), NOT an HMAC signature. Exactly-once minting
  # is arbitrated by CoinflowPurchase#begin_fulfillment! via Coinflow::Fulfillment.
  class CoinflowController < ApplicationController
    # Raised only to be captured — a settlement that moved money but minted
    # nothing. Never propagated: Coinflow does not retry, so raising for real
    # would only 500 the ack without recovering anything.
    SettlementAnomaly = Class.new(StandardError)

    skip_before_action :verify_authenticity_token
    skip_before_action :require_authentication
    skip_before_action :detect_geo_state
    skip_before_action :require_profile_completion

    def create
      raw_body = request.body.read

      # Shared-secret auth FIRST — cheap, constant-time, fails closed. A wrong
      # (or missing) Authorization header is the whole defense between an
      # attacker and free token minting.
      unless Coinflow::Client.new.verify_webhook_auth(request.headers["Authorization"])
        Rails.logger.warn "[tokens] coinflow.webhook.bad_auth"
        return head :unauthorized
      end

      begin
        event = JSON.parse(raw_body)
      rescue JSON::ParserError
        Rails.logger.warn "[tokens] coinflow.webhook.bad_json"
        return head :bad_request
      end

      event_type = (event["eventType"] || event["type"]).to_s
      payment_id = event["id"].to_s
      Rails.logger.info "[tokens] coinflow.webhook.received type=#{event_type} id=#{payment_id}"

      # OPSEC-033 parity: refuse sandbox events in production at the controller
      # boundary. A sandbox-configured client (COINFLOW_API_BASE) is the tell.
      # Return 200 to ack (never retry-loop the sender).
      if Rails.env.production? && Coinflow::Client.sandbox?
        Rails.logger.warn "[tokens] coinflow.webhook.rejected_sandbox_event_in_production type=#{event_type} id=#{payment_id}"
        return head :ok
      end

      # OPSEC-033 parity: an event for a different merchant is not ours.
      merchant_id = ENV["COINFLOW_MERCHANT_ID"].to_s
      if merchant_id.present? && event["merchantId"].present? && event["merchantId"].to_s != merchant_id
        Rails.logger.warn "[tokens] coinflow.webhook.merchant_mismatch event_merchant=#{event['merchantId']} id=#{payment_id}"
        return head :ok
      end

      case event_type
      when "Settled"
        handle_settled(event)
      when "Card Payment Authorized"
        # Pre-capture authorization — funds NOT yet settled. Log only; the
        # `Settled` event is what mints.
        Rails.logger.info "[tokens] coinflow.webhook.card_authorized id=#{payment_id} (pre-settlement, no mint)"
      else
        Rails.logger.info "[tokens] coinflow.webhook.ignored type=#{event_type} id=#{payment_id}"
      end

      head :ok
    end

    private

    # `Settled` — funds reached settlement. Resolve the purchase, dedup a
    # redelivered event, validate the amount against the pack (never trust the
    # sender), then hand off to the exactly-once mint gate.
    def handle_settled(event)
      payment_id = event["id"].to_s
      purchase   = purchase_for_event(event)
      unless purchase
        # A redelivery of a settlement we ALREADY recorded looks identical to a
        # genuine orphan here: tier-3 resolution only sees `pending` rows, so
        # once the first delivery captured the row, the second resolves to
        # nothing. Webhooks arrive more than once by design, so treating that as
        # an anomaly files a false alarm on every redelivery — and an ErrorLog
        # stream full of false alarms is one nobody reads. The payment id is
        # unique per settlement and we stamp it at capture, so its presence on
        # any row proves this settlement was already handled.
        if payment_id.present? && CoinflowPurchase.exists?(coinflow_payment_id: payment_id)
          Rails.logger.info "[tokens] coinflow.webhook.redelivery id=#{payment_id} " \
                            "— already recorded, nothing owed"
          return
        end

        Rails.logger.error "[tokens] coinflow.webhook.settled UNMATCHED id=#{payment_id} " \
                           "customer=#{event['customerId']} — manual review required"
        record_settlement_anomaly!(
          "Coinflow settlement matched no pending purchase — funds settled, nothing minted. " \
          "payment_id=#{payment_id} customer=#{event['customerId']} " \
          "subtotal_cents=#{subtotal_field(event, 'cents')}"
        )
        return
      end

      TokensLogger.dump("coinflow.webhook.settled_payload", {
        payment_id: payment_id,
        subtotal: event["subtotal"],
        fees: event["fees"],
        total: event["total"],
        merchant_id: event["merchantId"],
        customer_id: event["customerId"]
      })

      # Dedup (webhooks may arrive more than once): this exact settlement already
      # drove this purchase to minted — ack and stop.
      if purchase.coinflow_payment_id == payment_id && purchase.status == "minted"
        Rails.logger.info "[tokens] coinflow.webhook.duplicate id=#{payment_id} purchase=#{purchase.id} already minted"
        return
      end

      unless purchase.capture_matches?(event)
        Rails.logger.warn "[tokens] coinflow.webhook.settled_rejected purchase=#{purchase.id} " \
                          "subtotal=#{subtotal_field(event, 'cents')} " \
                          "currency=#{subtotal_field(event, 'currency')} " \
                          "expected=#{purchase.expected_amount_cents}"
        record_settlement_anomaly!(
          "Coinflow settlement rejected on amount mismatch — funds settled, nothing minted. " \
          "purchase=#{purchase.id} payment_id=#{payment_id} " \
          "settled_cents=#{subtotal_field(event, 'cents')} " \
          "currency=#{subtotal_field(event, 'currency')} " \
          "expected_cents=#{purchase.expected_amount_cents}"
        )
        return
      end

      if Coinflow::Fulfillment.enqueue_mint!(purchase, payment_id: payment_id)
        Rails.logger.info "[tokens] coinflow.webhook.job_enqueued purchase=#{purchase.id}"
      else
        # enqueue_mint! declined. Two very different things land here and they
        # used to be indistinguishable at INFO:
        #
        #   BENIGN — a redelivery of the settlement this row already recorded.
        #   Nothing owed; the recorded payment id matches.
        #
        #   MONEY — a DIFFERENT settlement that lost the begin_fulfillment! CAS
        #   on this row. Two settlements, one mint: the buyer paid twice and was
        #   minted once. The recorded payment id is the tell — it belongs to the
        #   settlement that won, so a mismatch means this one was dropped.
        recorded = purchase.coinflow_payment_id
        if recorded.present? && payment_id.present? && recorded != payment_id
          Rails.logger.error "[tokens] coinflow.webhook.settlement_lost purchase=#{purchase.id} " \
                             "incoming=#{payment_id} recorded=#{recorded} status=#{purchase.status}"
          record_settlement_anomaly!(
            "Coinflow settlement lost a concurrent race — a SECOND settlement hit a row " \
            "already claimed by another, so the buyer may have paid twice and minted once. " \
            "purchase=#{purchase.id} incoming_payment_id=#{payment_id} " \
            "recorded_payment_id=#{recorded} status=#{purchase.status} " \
            "settled_cents=#{subtotal_field(event, 'cents')}"
          )
        else
          Rails.logger.info "[tokens] coinflow.webhook.already_fulfilled purchase=#{purchase.id} status=#{purchase.status}"
        end
      end
    end

    # Tiered resolution (Webhooks::PaypalController#purchase_for_capture
    # parity). Coinflow's create-checkout-link body carries no invoice field, so
    # the primary path is the customerId echoed from x-coinflow-auth-user-id.
    #   Tier 1 — an explicit reference field, if the payload carries one.
    #   Tier 2 — customerId AS a reference (if the operator keys
    #            x-coinflow-auth-user-id to the reference).
    #   Tier 3 — customerId as "tm_user_<id>" → the user's oldest pending row
    #            AT THE SETTLED PRICE (CoinflowPurchase.pending_for_settlement).
    #            Oldest-first still lets N concurrent settlements consume N
    #            pending rows, one token each, but only among rows that cost the
    #            same — otherwise a stale $19 row absorbs a $49 trio settlement
    #            and the buyer is charged for tokens that never mint.
    def purchase_for_event(event)
      reference = event["reference"].presence || subtotal_field(event, "reference").presence
      if reference && (purchase = CoinflowPurchase.for_reference(reference).first)
        return purchase
      end

      customer_id = event["customerId"].to_s
      if customer_id.present? && (purchase = CoinflowPurchase.for_reference(customer_id).first)
        return purchase
      end

      if (user_id = customer_id[/\Atm_user_(\d+)\z/, 1])
        return CoinflowPurchase.pending_for_settlement(
          user_id: user_id, cents: subtotal_field(event, "cents")
        )
      end

      nil
    end

    # Money moved and nothing minted — the one class of failure that MUST be
    # diagnosable in seconds (backend discipline), and the one this controller
    # previously swallowed into a bare logger.warn. ErrorLog is the operator's
    # triage view (and fans out to Sentry); a log line in a webhook nobody tails
    # is not a signal. Constructed rather than raised — capture! tolerates a nil
    # backtrace, and raising here would only break the 200 ack Coinflow needs.
    # Never let telemetry take down fulfillment: a logging failure is swallowed.
    def record_settlement_anomaly!(message)
      ErrorLog.capture!(SettlementAnomaly.new(message))
    rescue StandardError => e
      Rails.logger.error "[tokens] coinflow.webhook.error_log_failed #{e.class}: #{e.message}"
    end

    # Fail-closed read of a `subtotal` sub-field. Coinflow documents `subtotal`
    # as a {cents:, currency:} hash; a malformed payload (e.g. a bare integer)
    # would make `event.dig("subtotal", key)` raise TypeError → a webhook 500
    # (and a Coinflow retry-loop). Read every subtotal sub-field through this so
    # a malformed payload degrades to nil, mirroring
    # CoinflowPurchase#capture_matches? — no mint, ack the sender, never 500.
    def subtotal_field(event, key)
      subtotal = event["subtotal"]
      subtotal.is_a?(Hash) ? subtotal[key] : nil
    end
  end
end
