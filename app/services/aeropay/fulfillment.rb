module Aeropay
  # Exactly-once bridge from a validated Aeropay `transaction_completed` to the
  # on-chain mint (Coinflow::Fulfillment parity). Only Webhooks::AeropayController
  # funnels through here — Aeropay's bank-payment flow has no client-side capture
  # leg, so the `transaction_completed` webhook is the single fulfillment source
  # of truth.
  #
  # PERSIST-BEFORE-MINT: the AeropayPurchase row is created (pending) in
  # TokensController#aeropay_order, stamped with the deposit's transaction id,
  # and marked `captured` by begin_fulfillment! here BEFORE TokenPurchaseJob
  # mints anything. We never mint then record — the captured row is the durable
  # record that the settlement happened, so a crash between settlement and mint
  # is recoverable, never a silent double-send — the transfer-then-record
  # double-pay trap that StripeDepositJob's deposit path itself closed by
  # claiming its TransactionLog row before it funds.
  #
  # SETTLEMENT CAVEAT: for a standard ACH pay-in, `transaction_completed` means
  # APPROVED, not settled (funds final ~3 business days later). Production should
  # prefer the instant RfP/RTP pay-in (irrevocable) so funds are final before
  # this mint fires. See Aeropay::Client#create_deposit.
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
    def enqueue_mint!(purchase, transaction_id:)
      won = purchase.begin_fulfillment!(capture_id: transaction_id)
      return false unless won || stranded?(purchase)

      # B4 / OPSEC-036/048: never mint for a frozen or risk-flagged account. The
      # settlement above is still recorded (the money DID move — forensics keep
      # the trail), but the on-chain mint waits for operator review.
      user = purchase.user
      if user.frozen? || user.payment_risk_flag
        Rails.logger.error "[tokens] aeropay.mint_blocked purchase=#{purchase.id} user=#{user.id} " \
                           "frozen=#{user.frozen?} risk_flag=#{user.payment_risk_flag} " \
                           "— captured but NOT minting, manual review required"
        return false
      end

      TokenPurchaseJob.perform_later(
        user_id: purchase.user_id,
        pack_id: purchase.pack_id,
        wallet_address: purchase.wallet_address,
        purchase_type: "aeropay",
        aeropay_reference: purchase.aeropay_reference
      )
      Rails.logger.info "[tokens] aeropay.mint_enqueued purchase=#{purchase.id} " \
                        "reference=#{purchase.aeropay_reference} won_cas=#{won}"
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
