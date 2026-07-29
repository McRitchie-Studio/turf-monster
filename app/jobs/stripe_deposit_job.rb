class StripeDepositJob < ApplicationJob
  queue_as :default

  # v0.16: deposit-to-vault is gone. USDC now lands in the user's own ATA
  # (managed or Phantom — same destination, same flow). No `vault.deposit`
  # step afterwards; the user's USDC is immediately spendable from their
  # ATA via enter_contest's SPL transfer.
  def perform(user_id:, amount_cents:, wallet_address:, stripe_session_id:)
    user = User.find_by(id: user_id)
    return unless user

    # OPSEC-022 / money-path (2026-07 CRITICAL): CLAIM THE ROW BEFORE THE
    # IRREVERSIBLE TRANSFER. `fund_user` moves USDC on-chain and cannot be
    # undone, so idempotency has to be WON before it runs, not RECORDED after.
    # The partial unique index on stripe_session_id (migration
    # 20260524000013) makes this create! the atomic claim: a re-delivered
    # webhook, a concurrent worker, or an ApplicationJob `retry_on` re-run all
    # collide here (RecordNotUnique) and return WITHOUT ever transferring.
    #
    # The pre-fix ordering recorded the row AFTER the transfer, leaving a
    # window where a transient error between transfer and record! (retried) —
    # or a duplicate delivery — paid the user 2-3x. See the regression tests
    # in test/jobs/stripe_deposit_job_test.rb.
    log = begin
      TransactionLog.record!(
        user: user,
        type: "deposit",
        amount_cents: amount_cents,
        direction: "credit",
        status: "pending",
        description: "Stripe deposit $#{'%.2f' % (amount_cents / 100.0)}",
        metadata: { method: "stripe" },
        stripe_session_id: stripe_session_id  # OPSEC-022
      )
    rescue ActiveRecord::RecordNotUnique
      # Lost the claim race — another delivery/worker/retry already owns this
      # session and performs (or performed) the single transfer. We must not.
      # (Rescue-and-return is sound only because perform runs no OUTER
      # transaction — do NOT wrap this job body in `transaction do`, or the
      # unique violation would abort the surrounding tx and this continue
      # would be unsafe.)
      Rails.logger.info("[StripeDepositJob] duplicate stripe_session_id=#{stripe_session_id} — claim already held, skipping")
      return
    end

    vault = Solana::Vault.new
    amount_lamports = Solana::Config.dollars_to_lamports(amount_cents / 100.0)

    # Ensure user has both a UserAccount PDA (stats + seeds + username) and
    # a USDC ATA (where the funds will land). Only the claim winner reaches here.
    vault.ensure_user_account(wallet_address, username: user.username) if user.solana_connected?
    vault.ensure_ata(wallet_address, mint: Solana::Config::USDC_MINT)

    # Devnet: mint USDC to user ATA. Mainnet: transfer USDC from admin
    # treasury ATA to user ATA. Either way, that's the entire on-chain
    # operation for a deposit in v0.16.
    fund_result = vault.fund_user(wallet_address, amount_lamports)

    # Transfer landed. Capture the signature DURABLY the instant fund_user
    # returns, in its OWN write, BEFORE flipping to completed (backend-discipline
    # §2: "capture durably, immediately"). If the completion write below faults
    # and retry_on re-runs perform, the claim above trips RecordNotUnique and we
    # return without re-transferring — the row is left `pending` WITH onchain_tx
    # set, the exact state Deposits::OnchainReconciler needs to CONFIRM the
    # signature on-chain and finalize it. (Pre-split, the signature was written
    # only in the completing update!, so a die-after-transfer stranded a
    # `pending` row with NO signature — unconfirmable, forcing needs_review.)
    sig = fund_result[:signature]
    log.update!(onchain_tx: sig) if sig.present?

    # Finalize. A fault here strands a reconcilable `pending`+signature row that
    # PendingDepositReconcilerJob (config/schedule.yml) heals on its next sweep;
    # it is NEVER re-transferred (the claim on stripe_session_id guarantees it).
    log.update!(status: "completed")
  end
end
