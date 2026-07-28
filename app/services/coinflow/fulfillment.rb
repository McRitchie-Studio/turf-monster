module Coinflow
  # Exactly-once bridge from a validated Coinflow settlement to the on-chain
  # mint (Paypal::Fulfillment parity). Only Webhooks::CoinflowController funnels
  # through here — Coinflow has no client-side capture leg, so the `Settled`
  # webhook is the single fulfillment source of truth.
  #
  # PERSIST-BEFORE-MINT: the CoinflowPurchase row is created (pending) in
  # TokensController#coinflow_order and marked `captured` by begin_fulfillment!
  # here BEFORE TokenPurchaseJob mints anything. We never mint then record — the
  # captured row is the durable record that the settlement happened, so a crash
  # between settlement and mint is recoverable, never a silent double-send —
  # the transfer-then-record double-pay trap that StripeDepositJob's deposit
  # path itself closed by claiming its TransactionLog row before it funds.
  module Fulfillment
    # How old a captured-but-unminted row must be before a redelivered webhook
    # treats it as stranded and re-enqueues. A fresh capture is almost always
    # mid-mint; sized past the worst-case mint loop plus the first Sidekiq retry
    # so we never run two jobs concurrently racing the same source_refs.
    STRANDED_AFTER = 5.minutes

    module_function

    # Enqueues TokenPurchaseJob when this caller wins the atomic
    # pending → captured transition, OR when the row has been stranded
    # captured-but-unminted past STRANDED_AFTER (a prior winner crashed between
    # the CAS and the mint completing). Fresh webhook redeliveries while the
    # winner's job is still minting are no-ops; the job's idempotency (OPSEC-009
    # source_ref + minted short-circuit) is the backstop. Returns true when a
    # job was enqueued.
    def enqueue_mint!(purchase, payment_id:)
      won = purchase.begin_fulfillment!(capture_id: payment_id)
      return false unless won || stranded?(purchase)

      # B4 / OPSEC-036/048: never mint for a frozen or risk-flagged account. The
      # settlement above is still recorded (the money DID move — forensics keep
      # the trail), but the on-chain mint waits for operator review.
      user = purchase.user
      if user.frozen? || user.payment_risk_flag
        Rails.logger.error "[tokens] coinflow.mint_blocked purchase=#{purchase.id} user=#{user.id} " \
                           "frozen=#{user.frozen?} risk_flag=#{user.payment_risk_flag} " \
                           "— captured but NOT minting, manual review required"
        return false
      end

      TokenPurchaseJob.perform_later(
        user_id: purchase.user_id,
        pack_id: purchase.pack_id,
        wallet_address: purchase.wallet_address,
        purchase_type: "coinflow",
        coinflow_reference: purchase.coinflow_reference
      )
      Rails.logger.info "[tokens] coinflow.mint_enqueued purchase=#{purchase.id} " \
                        "reference=#{purchase.coinflow_reference} won_cas=#{won}"
      true
    end

    # Captured, unminted, and old enough that the original job has clearly died.
    # A nil captured_at can't happen via the CAS — treat it as stale so an
    # anomalous row stays recoverable.
    def stranded?(purchase)
      purchase.status == "captured" &&
        purchase.tx_signatures.length < purchase.quantity &&
        (purchase.captured_at.nil? || purchase.captured_at <= STRANDED_AFTER.ago)
    end
  end
end
